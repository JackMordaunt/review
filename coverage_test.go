package main

import (
	"strings"
	"testing"
)

// A repository in which one new function is called and one is not.
func unreferencedRepo(t *testing.T) *repo {
	t.Helper()
	r := newRepo(t)
	r.write("go.mod", "module x\n\ngo 1.27.0\n")
	r.write("x.go", "package x\n")
	r.write("x_test.go", "package x\n")
	r.commit("first", "go.mod", "x.go", "x_test.go")
	r.write("x.go", `package x

// Used is called from the template below.
func Used() int { return 1 }

// Waiting is called from nowhere.
func Waiting() int { return 2 }

func lonely() int { return 3 }
`)
	r.write("page.tmpl", "{{ Used }}\n")
	return r
}

func TestCheckUnreferencedReadsTheWholeTree(t *testing.T) {
	r := unreferencedRepo(t)
	r.stage("x.go", "page.tmpl")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := checkUnreferenced(change)
	if len(got) != 1 || got[0].Rule != "new-symbol-unreferenced" || got[0].File != "x.go" {
		t.Fatalf("got %v", got)
	}
	for _, want := range []string{"Waiting", "lonely"} {
		if !strings.Contains(got[0].Message, want) {
			t.Errorf("%s missing from %s", want, got[0].Message)
		}
	}
	if strings.Contains(got[0].Message, "Used") {
		t.Errorf("a name the template uses was reported: %s", got[0].Message)
	}
}

// Against a range the tree is the range's end, not the working directory.
func TestCheckUnreferencedReadsARange(t *testing.T) {
	r := unreferencedRepo(t)
	rev := r.commit("second", "x.go", "page.tmpl")
	r.write("y.go", "package x\n\nvar _ = Waiting()\n") // The working tree, not the range.
	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := checkUnreferenced(change)
	if len(got) != 1 || !strings.Contains(got[0].Message, "Waiting") {
		t.Errorf("got %v", got)
	}
}

func TestReferenced(t *testing.T) {
	sources := map[string][]byte{
		"a.go": []byte("package x\n\nfunc Waiting() int { return 2 }\n"),
		"b.go": []byte("var _ = WaitingRoom\n"),
	}
	if referenced(Symbol{Name: "Waiting", File: "a.go", Line: 3}, sources) {
		t.Error("a prefix of another word counted as a reference")
	}
	sources["c.go"] = []byte("var _ = Waiting()\n")
	if !referenced(Symbol{Name: "Waiting", File: "a.go", Line: 3}, sources) {
		t.Error("a call was not counted")
	}
}

func TestCheckCodeWithoutTests(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.write("x_test.go", "package x\n")
	r.commit("first", "x.go", "x_test.go")
	parts := []string{"package x\n\n"}
	for i := 0; i < 60; i++ {
		parts = append(parts, "var v"+itoa(i)+" = "+itoa(i)+"\n")
	}
	r.write("x.go", strings.Join(parts, ""))
	r.stage("x.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := checkCodeWithoutTests(change)
	if len(got) != 1 || got[0].Rule != "code-without-tests" {
		t.Fatalf("got %v", got)
	}
	// Touching a test is enough; the check is about the habit, not the
	// coverage.
	r.write("x_test.go", "package x\n\n// touched\n")
	r.stage("x_test.go")
	change, err = Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if got := checkCodeWithoutTests(change); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

// A repository that keeps no tests is not asked to start with this change.
func TestCheckCodeWithoutTestsSparesAnUntestedRepository(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	parts := []string{"package x\n\n"}
	for i := 0; i < 60; i++ {
		parts = append(parts, "var v"+itoa(i)+" = "+itoa(i)+"\n")
	}
	r.write("x.go", strings.Join(parts, ""))
	r.stage("x.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if got := checkCodeWithoutTests(change); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}

// A method an encoder reaches for by reflection, and a function cgo exports
// to the host, are referenced by something the repository's text does not
// show.
func TestCalledByTheRuntime(t *testing.T) {
	for _, test := range []struct {
		symbol Symbol
		want   bool
	}{
		{Symbol{Name: "MarshalJSON", Kind: "func", File: "a.go"}, true},
		{Symbol{Name: "String", Kind: "func", File: "a.go"}, true},
		{Symbol{Name: "DllGetClassObject", Kind: "func", File: "a.go", Doc: "DllGetClassObject answers COM.\n\nexport DllGetClassObject"}, true},
		{Symbol{Name: "DllInstall", Kind: "func", File: "a.go", Doc: "export DllGetClassObject"}, false},
		{Symbol{Name: "String", Kind: "value", File: "a.go"}, false},
		{Symbol{Name: "Probe", Kind: "func", File: "a.go", Doc: "Probe reads the header."}, false},
	} {
		if got := calledByTheRuntime(test.symbol); got != test.want {
			t.Errorf("%s: %v, want %v", test.symbol.Name, got, test.want)
		}
	}
}
