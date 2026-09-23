package main

import "testing"

func TestCheckFormatting(t *testing.T) {
	for _, test := range []struct {
		changed, whitespace int
		fires               bool
	}{
		{100, 60, true},
		{100, 40, false},   // under the share
		{30, 20, true},     // just enough logic
		{25, 20, false},    // too little logic mixed in
		{1000, 995, false}, // a pure reformatting is not a mixture
		{20, 10, false},
		{0, 0, false},
	} {
		got := checkFormatting(&Change{Changed: test.changed, Whitespace: test.whitespace})
		if (len(got) == 1) != test.fires {
			t.Errorf("%d of %d whitespace: got %v", test.whitespace, test.changed, got)
		}
	}
}

// Through Gather, git counts the whitespace-only lines.
func TestGatherCountsWhitespaceOnlyLines(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n\nvar a = 1\nvar b = 2\nvar c = 3\n")
	r.commit("first", "x.go")
	r.write("x.go", "package x\n\nvar a  = 1\nvar b  = 2\nvar c = 4\n")
	r.stage("x.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	// Three lines changed on each side; two pairs differ only in spacing.
	if change.Changed != 6 || change.Whitespace != 4 {
		t.Errorf("changed %d, whitespace %d", change.Changed, change.Whitespace)
	}
}
