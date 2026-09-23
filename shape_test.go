package main

import (
	"strings"
	"testing"
)

func TestNesting(t *testing.T) {
	for _, test := range []struct {
		body string
		want int
	}{
		{"func f() {}", 0},
		{"func f() {\n\tif a {\n\t}\n}", 1},
		{"func f() {\n\tif a {\n\t\tfor b {\n\t\t\tswitch c {\n\t\t\t}\n\t\t}\n\t}\n}", 3},
		{"func f() {\n\ts := \"{{{\"\n\tr := `{`\n\t// {\n\t/* { */\n}", 0},
		{"func f() {\n\tc := '{'\n\tif a {\n\t}\n}", 1},
	} {
		if got := nesting(test.body); got != test.want {
			t.Errorf("%q: %d, want %d", test.body, got, test.want)
		}
	}
}

func TestCheckShape(t *testing.T) {
	long := "func f() {\n" + strings.Repeat("\tx++\n", maxFunctionLines) + "}"
	deep := "func g() {\n" + strings.Repeat("\tif a {\n", maxNesting+1) + strings.Repeat("\t}\n", maxNesting+1) + "}"
	c := &Change{Symbols: []Symbol{
		{Name: "f", Kind: "func", File: "x.go", Line: 1, Body: long},
		{Name: "g", Kind: "func", File: "x.go", Line: 200, Body: deep},
		{Name: "h", Kind: "func", File: "x.go", Line: 300, Body: "func h() {}"},
		{Name: "T", Kind: "type", File: "x.go", Line: 400},
	}}
	got := rulesOf(checkShape(c))
	if len(got) != 2 || got[0] != "function-too-long" || got[1] != "nesting-too-deep" {
		t.Errorf("got %v", got)
	}
}
