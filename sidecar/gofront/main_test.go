package main

import (
	"encoding/json"
	"strings"
	"testing"
)

const fixture = `// Package fixture is read by the test.
package fixture

import (
	"fmt"
	yaml "go.yaml.in/yaml/v4"
	"path/filepath"
)

// Limit bounds the work.
const Limit = 3

var (
	// count is kept between calls.
	count int
	name  = "x"
)

// Point is a place.
type Point struct {
	// X is across.
	X, Y int
	label string
}

// Move shifts the point.
func (p *Point) Move(dx int) { p.X += dx }

func helper() {
	const inner = 1
	type pair struct{ a, b int }
	f := func() {
		var deep = 2
		_ = deep
	}
	f()
	_ = inner
	fmt.Println(yaml.Marshal, filepath.Join)
}

func TestHelper(t *testing.T) { helper() }

/* block
comment */
func BenchmarkHelper(b *testing.B) {}
`

func TestReadFileListsEverything(t *testing.T) {
	file := readFile("fixture.go", []byte(fixture))
	if file.Error != "" {
		t.Fatal(file.Error)
	}
	if file.Package != "fixture" {
		t.Errorf("package %q", file.Package)
	}
	if got := strings.Join(file.Imports, ","); got != "fmt,yaml,filepath" {
		t.Errorf("imports %q", got)
	}
	want := map[string]Decl{
		"Limit":           {Kind: "const", Line: 11, Exported: true, Doc: "Limit bounds the work.", Text: "const Limit = 3"},
		"count":           {Kind: "var", Line: 15, Doc: "count is kept between calls.", Text: "count int"},
		"name":            {Kind: "var", Line: 16, Text: `name  = "x"`},
		"Point":           {Kind: "type", Line: 20, Exported: true, Doc: "Point is a place.", Text: "type Point struct {"},
		"X":               {Kind: "field", Line: 22, Exported: true, Doc: "X is across.", Text: "X, Y int"},
		"Y":               {Kind: "field", Line: 22, Exported: true, Doc: "X is across.", Text: "X, Y int"},
		"label":           {Kind: "field", Line: 23, Text: "label string"},
		"Move":            {Kind: "func", Line: 27, Exported: true, Doc: "Move shifts the point.", Text: "func (p *Point) Move(dx int) { p.X += dx }"},
		"helper":          {Kind: "func", Line: 29, Text: "func helper() {"},
		"inner":           {Kind: "const", Line: 30, Local: true, Text: "const inner = 1"},
		"pair":            {Kind: "type", Line: 31, Local: true, Text: "type pair struct{ a, b int }"},
		"a":               {Kind: "field", Line: 31, Local: true, Text: "type pair struct{ a, b int }"},
		"b":               {Kind: "field", Line: 31, Local: true, Text: "type pair struct{ a, b int }"},
		"deep":            {Kind: "var", Line: 33, Local: true, Text: "var deep = 2"},
		"TestHelper":      {Kind: "func", Line: 41, Exported: true, Test: true, Text: "func TestHelper(t *testing.T) { helper() }"},
		"BenchmarkHelper": {Kind: "func", Line: 45, Exported: true, Test: true, Doc: "block\ncomment", Text: "func BenchmarkHelper(b *testing.B) {}"},
	}
	if len(file.Decls) != len(want) {
		names := []string{}
		for _, d := range file.Decls {
			names = append(names, d.Name)
		}
		t.Errorf("%d declarations %v, want %d", len(file.Decls), names, len(want))
	}
	for _, got := range file.Decls {
		w, ok := want[got.Name]
		if !ok {
			t.Errorf("unexpected %+v", got)
			continue
		}
		w.Name = got.Name
		w.EndLine = got.EndLine
		if got != w {
			t.Errorf("%s:\n got %+v\nwant %+v", got.Name, got, w)
		}
		if got.EndLine < got.Line {
			t.Errorf("%s ends on %d before it starts on %d", got.Name, got.EndLine, got.Line)
		}
	}
	for _, d := range file.Decls {
		if d.Name == "helper" && d.EndLine != 39 {
			t.Errorf("helper ends on %d, want 39", d.EndLine)
		}
	}
	comments := map[int]string{}
	for _, c := range file.Comments {
		comments[c.Line] = c.Text
	}
	for line, text := range map[int]string{1: "Package fixture is read by the test.", 14: "count is kept between calls.", 43: "/* block\ncomment */"} {
		if comments[line] != text {
			t.Errorf("comment on %d: %q, want %q", line, comments[line], text)
		}
	}
}

func TestReadFileReportsAParseError(t *testing.T) {
	file := readFile("broken.go", []byte("package x\nfunc {"))
	if file.Error == "" || len(file.Decls) != 0 {
		t.Errorf("%+v", file)
	}
	data, err := json.Marshal(Output{Files: []File{file}})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"imports":[]`, `"decls":[]`, `"comments":[]`, `"error":`} {
		if !strings.Contains(string(data), key) {
			t.Errorf("%s missing from %s", key, data)
		}
	}
}
