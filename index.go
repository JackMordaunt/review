package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
)

// Declared is one declaration somewhere in the repository, which a new name
// might turn out to duplicate.
type Declared struct {
	Name string
	Kind string
	File string
	Line int
	// Text is the line it was declared on, which is what shows a reader that
	// two constants hold the same number.
	Text string
}

func (d Declared) String() string {
	return fmt.Sprintf("%s:%d: %s", d.File, d.Line, strings.TrimSpace(d.Text))
}

// Index reads every declaration in the repository. It is built by parsing
// rather than by searching: a pattern over lines misses an indented constant
// inside a block, which is exactly where a duplicated fact tends to live.
func Index(root, rev string) ([]Declared, error) {
	out, err := git(root, "ls-files", "*.go")
	if err != nil {
		return nil, err
	}
	var index []Declared
	for _, name := range strings.Split(strings.TrimSpace(out), "\n") {
		if name == "" || strings.HasSuffix(name, "_test.go") {
			continue
		}
		source, err := at(root, rev, name)
		if err != nil {
			continue
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, name, source, 0)
		if err != nil {
			continue
		}
		lines := strings.Split(string(source), "\n")
		at := func(pos token.Pos) (int, string) {
			line := fset.Position(pos).Line
			if line-1 < 0 || line-1 >= len(lines) {
				return line, ""
			}
			return line, lines[line-1]
		}
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				line, text := at(d.Pos())
				index = append(index, Declared{Name: d.Name.Name, Kind: "func", File: name, Line: line, Text: text})
			case *ast.GenDecl:
				for _, spec := range d.Specs {
					switch s := spec.(type) {
					case *ast.TypeSpec:
						line, text := at(s.Pos())
						index = append(index, Declared{Name: s.Name.Name, Kind: "type", File: name, Line: line, Text: text})
						// A struct's fields are declarations too, and a field
						// is where a restated fact often sits.
						if structure, ok := s.Type.(*ast.StructType); ok {
							for _, field := range structure.Fields.List {
								for _, ident := range field.Names {
									line, text := at(ident.Pos())
									index = append(index, Declared{Name: ident.Name, Kind: "field", File: name, Line: line, Text: text})
								}
							}
						}
					case *ast.ValueSpec:
						for _, ident := range s.Names {
							line, text := at(ident.Pos())
							index = append(index, Declared{Name: ident.Name, Kind: kindOf(d.Tok), File: name, Line: line, Text: text})
						}
					}
				}
			}
		}
	}
	return index, nil
}

func kindOf(tok token.Token) string {
	switch tok {
	case token.CONST:
		return "const"
	case token.VAR:
		return "var"
	}
	return "value"
}

// Resembling returns the declarations whose names share a word with the one
// given, which is the shortlist a reader is asked to judge. Its own
// declaration is left out, since a name always resembles itself.
func Resembling(index []Declared, symbol Symbol, limit int) []string {
	words := split(symbol.Name)
	var out []string
	seen := map[string]bool{}
	for _, word := range words {
		if len(word) < 4 {
			continue
		}
		lower := strings.ToLower(word)
		for _, declared := range index {
			if declared.File == symbol.File && declared.Line == symbol.Line {
				continue
			}
			if !strings.Contains(strings.ToLower(declared.Name), lower) {
				continue
			}
			line := declared.String()
			if seen[line] {
				continue
			}
			seen[line] = true
			out = append(out, line)
			if len(out) >= limit {
				return out
			}
		}
	}
	return out
}

// same reports whether two declarations hold the same literal, which is the
// cheapest signal that a fact has been written twice. It is a hint for the
// shortlist, not a finding.
func same(a, b Declared) bool {
	_, left, okA := strings.Cut(a.Text, "=")
	_, right, okB := strings.Cut(b.Text, "=")
	return okA && okB && strings.TrimSpace(left) == strings.TrimSpace(right)
}

// split breaks a name into the words it is made of, so that Assemble finds
// assemble and icoEntrySize finds both Entry and Size.
func split(name string) []string {
	var (
		words []string
		word  strings.Builder
	)
	for i, r := range name {
		if i > 0 && r >= 'A' && r <= 'Z' {
			words = append(words, word.String())
			word.Reset()
		}
		word.WriteRune(r)
	}
	if word.Len() > 0 {
		words = append(words, word.String())
	}
	return words
}
