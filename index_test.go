package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestSplit(t *testing.T) {
	for _, test := range []struct {
		name string
		want []string
	}{
		{"Assemble", []string{"Assemble"}},
		{"icoEntrySize", []string{"ico", "Entry", "Size"}},
		{"groupHeaderSize", []string{"group", "Header", "Size"}},
		{"Stored", []string{"Stored"}},
		{"", nil},
		{"x", []string{"x"}},
		// An acronym splits per letter. Words shorter than four characters
		// are dropped by the caller, so this costs nothing.
		{"ID", []string{"I", "D"}},
	} {
		if got := split(test.name); !reflect.DeepEqual(got, test.want) {
			t.Errorf("split(%q) = %v, want %v", test.name, got, test.want)
		}
	}
}

func TestSame(t *testing.T) {
	for _, test := range []struct {
		left, right string
		want        bool
	}{
		{"\tgroupHeaderSize = 6", "\tdirectorySize = 6", true},
		{"const icoEntrySize = 16", "\tentrySize = 16", true},
		{"const a = 6", "const b = 7", false},
		{"const a = 6", "type T struct{}", false},
		{"type T struct{}", "type U struct{}", false},
		{"x := 6", "const y = 6", true},
		{"\tmagic = \"PE\\x00\\x00\"", "\theader = \"PE\\x00\\x00\"", true},
	} {
		got := same(Declared{Text: test.left}, Declared{Text: test.right})
		if got != test.want {
			t.Errorf("same(%q, %q) = %v, want %v", test.left, test.right, got, test.want)
		}
	}
}

func TestIndex(t *testing.T) {
	r := newRepo(t)
	r.write("ico/writer.go", `package ico

const (
	directorySize = 6
	entrySize     = 16
)

type Entry struct {
	Width  int
	Offset int
}

func Write() {}

var ErrNoIcons = errorString("none")
`)
	// Tests are not part of the index: a duplicate in a test is not a fact
	// with two owners.
	r.write("ico/writer_test.go", "package ico\n\nconst directorySize = 99\n")
	rev := r.commit("first", "ico/writer.go", "ico/writer_test.go")

	index, err := GoFrontend{}.Whole(r.Root, rev+".."+rev)
	if err != nil {
		t.Fatal(err)
	}
	kinds := map[string]string{}
	for _, d := range index {
		if kinds[d.Name] != "" {
			t.Errorf("%s indexed twice", d.Name)
		}
		kinds[d.Name] = d.Kind
	}
	want := map[string]string{
		"directorySize": "const",
		"entrySize":     "const",
		"Entry":         "type",
		"Width":         "field",
		"Offset":        "field",
		"Write":         "func",
		"ErrNoIcons":    "var",
	}
	if !reflect.DeepEqual(kinds, want) {
		t.Errorf("got %v, want %v", kinds, want)
	}

	// An indented constant inside a block is exactly where a duplicated fact
	// lives, so its declaring line has to survive into the index.
	for _, d := range index {
		if d.Name == "entrySize" {
			if !strings.Contains(d.Text, "16") {
				t.Errorf("entrySize carries no value: %q", d.Text)
			}
			if d.File != "ico/writer.go" || d.Line != 5 {
				t.Errorf("entrySize located at %s:%d, want ico/writer.go:5", d.File, d.Line)
			}
		}
	}
}

func TestIndexSkipsUnparseableFiles(t *testing.T) {
	r := newRepo(t)
	r.write("good.go", "package x\n\nconst a = 1\n")
	r.write("bad.go", "package x\n\nfunc (\n")
	rev := r.commit("first", "good.go", "bad.go")

	index, err := GoFrontend{}.Whole(r.Root, rev+".."+rev)
	if err != nil {
		t.Fatal(err)
	}
	if len(index) != 1 || index[0].Name != "a" {
		t.Errorf("got %v, want only a", index)
	}
}

func TestResembling(t *testing.T) {
	index := []Declared{
		{Name: "entrySize", File: "ico/writer.go", Line: 5, Text: "\tentrySize = 16"},
		{Name: "directorySize", File: "ico/writer.go", Line: 4, Text: "\tdirectorySize = 6"},
		{Name: "Entry", File: "ico/ico.go", Line: 10, Text: "type Entry struct {"},
		{Name: "colour", File: "png/png.go", Line: 3, Text: "var colour int"},
	}
	symbol := Symbol{Name: "icoEntrySize", File: "exe/exe.go", Line: 12}

	got := Resembling(index, symbol, 16)
	joined := strings.Join(got, "\n")
	for _, want := range []string{"entrySize", "Entry", "directorySize"} {
		if !strings.Contains(joined, want) {
			t.Errorf("%s missing from the shortlist:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "colour") {
		t.Errorf("an unrelated name reached the shortlist:\n%s", joined)
	}
	// "ico" is three letters, so it contributes nothing and cannot drag in
	// every declaration in the ico package.
	if len(got) != 3 {
		t.Errorf("got %d candidates, want 3:\n%s", len(got), joined)
	}
}

func TestResemblingLeavesOutItself(t *testing.T) {
	index := []Declared{
		{Name: "entrySize", File: "exe/exe.go", Line: 12, Text: "\tentrySize = 16"},
		{Name: "entrySize", File: "ico/ico.go", Line: 4, Text: "\tentrySize = 16"},
	}
	got := Resembling(index, Symbol{Name: "entrySize", File: "exe/exe.go", Line: 12}, 16)
	if len(got) != 1 || !strings.Contains(got[0], "ico/ico.go") {
		t.Errorf("got %v, want only the declaration elsewhere", got)
	}
}

func TestResemblingObeysItsLimit(t *testing.T) {
	var index []Declared
	for i := range 40 {
		index = append(index, Declared{Name: "entrySize", File: "x.go", Line: i + 1, Text: "entrySize = 1"})
	}
	if got := Resembling(index, Symbol{Name: "entrySize", File: "y.go"}, 16); len(got) != 16 {
		t.Errorf("got %d candidates, want the limit of 16", len(got))
	}
}

func TestDeclaredString(t *testing.T) {
	d := Declared{File: "ico/writer.go", Line: 4, Text: "\tdirectorySize = 6\t"}
	if got := d.String(); got != "ico/writer.go:4: directorySize = 6" {
		t.Errorf("got %q", got)
	}
}
