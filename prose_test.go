package main

import "testing"

func TestRestates(t *testing.T) {
	for _, test := range []struct {
		comment Located
		want    bool
	}{
		{Located{Text: "set the name", Below: "setName(x)"}, true},
		{Located{Text: "Increment the counter.", Below: "counter++"}, false},
		{Located{Text: "close the file", Below: "file.Close()"}, true},
		{Located{Text: "Windows refuses an unordered group.", Below: "sort(rows)"}, false},
		{Located{Text: "name", Below: "name := x"}, false},
		{Located{Text: "TODO set the name", Below: "setName(x)"}, false},
		{Located{Text: "set the name", Below: ""}, false},
		{Located{Text: "review:ignore no-stutter the name", Below: "IcoEntry"}, false},
	} {
		if got := restates(test.comment); got != test.want {
			t.Errorf("%q over %q: %v, want %v", test.comment.Text, test.comment.Below, got, test.want)
		}
	}
}

func TestCheckRestatingAndTheClaimsPacket(t *testing.T) {
	c := &Change{Comments: []Located{
		{Text: "set the name", File: "x.go", Line: 3, Below: "setName(x)"},
		{Text: "Windows refuses an unordered group, so", File: "x.go", Line: 7, Below: "sort(rows)"},
		{Text: "the rows are sorted first.", File: "x.go", Line: 8, Below: "sort(rows)"},
	}}
	got := checkRestating(c)
	if len(got) != 1 || got[0].Rule != "comment-restates-code" || got[0].Line != 3 || got[0].Severity != Note {
		t.Errorf("got %v", got)
	}
	blocks := commentBlocks(c.Comments)
	if len(blocks) != 1 || len(blocks[0]) != 2 {
		t.Errorf("got %v, want one block of two lines", blocks)
	}
}

func TestCodeBelow(t *testing.T) {
	lines := []string{"// says", "", "// more", "a()", "b()", "", "c()"}
	if got := codeBelow(lines, 1); got != "a()\nb()" {
		t.Errorf("got %q", got)
	}
	if got := codeBelow(lines, 7); got != "" {
		t.Errorf("got %q", got)
	}
}
