package main

import (
	"fmt"
	"strings"
	"testing"
)

// body is a Go function long enough to compare, built from a name and the
// names of the two values it works on.
func body(name, a, b string) string {
	return fmt.Sprintf(`func %s(%s []int, %s int) int {
	total := 0
	for _, v := range %s {
		if v > %s {
			total += v
		} else if v == %s {
			total -= v
		} else {
			total++
		}
	}
	if total < 0 {
		return -total
	}
	if total > 1000 {
		return 1000
	}
	for i := 0; i < len(%s); i++ {
		total += i * 2
	}
	return total
}`, name, a, b, a, b, b, a)
}

// small is a wrapper of the shape every wrapper has, too short for a match
// in shape to mean anything, though long enough for an exact copy to.
func small(name, kind string) string {
	return fmt.Sprintf(`func %s(raw string) (%s, error) {
	var r %s
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return %s{}, fmt.Errorf("reading the answer: %%w", err)
	}
	return r, nil
}`, name, kind, kind, kind)
}

func TestCheckClonesFindsAnExactCopy(t *testing.T) {
	c := &Change{
		Symbols: []Symbol{{Name: "sumAbove", Kind: "func", File: "b.go", Line: 10, Body: body("sumAbove", "xs", "floor")}},
		index:   []Declared{{Name: "sumAll", Kind: "func", File: "a.go", Line: 3, Body: body("sumAll", "xs", "floor")}},
	}
	got := checkClones(c)
	if len(got) != 1 || got[0].Rule != "duplicate-body" || got[0].Severity != MustFix {
		t.Fatalf("got %v", got)
	}
	if !strings.Contains(got[0].Message, "a.go:3") || got[0].Symbol != "sumAbove" {
		t.Errorf("got %v", got[0])
	}
}

func TestCheckClonesFindsTheSameShape(t *testing.T) {
	c := &Change{
		Symbols: []Symbol{{Name: "sumAbove", Kind: "func", File: "b.go", Line: 10, Body: body("sumAbove", "rows", "limit")}},
		index:   []Declared{{Name: "sumAll", Kind: "func", File: "a.go", Line: 3, Body: body("sumAll", "xs", "floor")}},
	}
	got := checkClones(c)
	if len(got) != 1 || got[0].Severity != Consider {
		t.Fatalf("got %v", got)
	}
}

func TestCheckClonesReadsTwoNewFunctionsOnce(t *testing.T) {
	c := &Change{Symbols: []Symbol{
		{Name: "one", Kind: "func", File: "a.go", Line: 3, Body: body("one", "xs", "floor")},
		{Name: "two", Kind: "func", File: "a.go", Line: 30, Body: body("two", "xs", "floor")},
	}}
	got := checkClones(c)
	if len(got) != 1 || got[0].Symbol != "two" {
		t.Fatalf("got %v", got)
	}
}

func TestCheckClonesIgnoresWhatIsTooSmallOrDifferent(t *testing.T) {
	c := &Change{
		Symbols: []Symbol{
			{Name: "Size", Kind: "func", File: "b.go", Line: 10, Body: "func (e Entry) Size() int { return e.size }"},
			{Name: "other", Kind: "func", File: "b.go", Line: 20, Body: body("other", "xs", "floor") + "\n// and more\nvar _ = 1"},
		},
		index: []Declared{
			{Name: "Len", Kind: "func", File: "a.go", Line: 3, Body: "func (e Entry) Len() int { return e.size }"},
			{Name: "sumAll", Kind: "func", File: "a.go", Line: 3, Body: body("sumAll", "xs", "floor")},
		},
	}
	if got := checkClones(c); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

// A small wrapper matches another only exactly: two wrappers share a shape
// because wrappers do.
func TestCheckClonesAsksMoreOfAShapeThanOfACopy(t *testing.T) {
	c := &Change{
		Symbols: []Symbol{{Name: "decodeB", Kind: "func", File: "b.go", Line: 10, Body: small("decodeB", "verdicts")}},
		index:   []Declared{{Name: "decodeA", Kind: "func", File: "a.go", Line: 3, Body: small("decodeA", "reported")}},
	}
	if got := checkClones(c); len(got) != 0 {
		t.Errorf("a small wrapper matched in shape: %v", got)
	}
	c.Symbols[0].Body = small("decodeB", "reported")
	if got := checkClones(c); len(got) != 1 || got[0].Severity != MustFix {
		t.Errorf("a small copy was not reported: %v", got)
	}
}

// Comments and whitespace are not part of a body's shape.
func TestNormaliseReadsThroughCommentsAndSpace(t *testing.T) {
	a := normalise(body("f", "xs", "n"), "f", "go")
	b := normalise(strings.ReplaceAll(body("f", "xs", "n"), "total := 0", "total := 0 // start\n\n"), "f", "go")
	if a.exact != b.exact {
		t.Errorf("a comment changed the shape:\n%s\n%s", a.exact, b.exact)
	}
	if !strings.Contains(a.exact, "NAME") || strings.Contains(a.exact, " f ") {
		t.Errorf("the function's own name was kept: %s", a.exact)
	}
	if !strings.Contains(a.structural, "for ID , ID := range ID") {
		t.Errorf("keywords were not kept: %s", a.structural)
	}
}
