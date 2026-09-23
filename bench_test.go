package main

import (
	"strings"
	"testing"
)

// The bench runs the deterministic checks over recent commits and counts
// what fired, per rule, so a rule's precision is a number.
func TestBench(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	r.write("x.go", "package x\n\nvar cfg = 1\n")
	r.commit("x: add cfg", "x.go")
	r.write("x.go", "package x\n\nvar cfg = 1\n\nvar y = 2\n")
	r.commit("oops", "x.go")
	t.Chdir(r.Root)

	out := capture(t, func() {
		if err := bench([]string{"-n", "10"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "2 commits measured") {
		t.Errorf("the root commit was not left out:\n%s", out)
	}
	for _, want := range []string{"abbreviation", "message-frustration"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q did not fire:\n%s", want, out)
		}
	}
	one := capture(t, func() {
		if err := bench([]string{"-n", "10", "-rule", "message-frustration"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(one, "oops") || !strings.Contains(one, "fired on 1 of 2 commits") {
		t.Errorf("got %s", one)
	}
	none := capture(t, func() {
		if err := bench([]string{"-n", "10", "-author", "nobody@example.com"}); err == nil {
			t.Error("no commits to measure should be an error")
		}
	})
	_ = none
}
