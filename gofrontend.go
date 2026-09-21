package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"slices"
	"strings"
)

// GoFrontend reads Go through the standard library's parser, which is the
// grammar Go ships with itself.
type GoFrontend struct{}

func (GoFrontend) Name() string { return "go" }

func (GoFrontend) Covers(path string) bool { return strings.HasSuffix(path, ".go") }

func (GoFrontend) Features() Features {
	return FeatSymbols | FeatTests | FeatComments | FeatIndex
}

// Change appends the declarations, tests and prose the added lines of the
// change's Go files introduce. Only what the diff added is reported, so a job
// sees new work rather than the file it landed in.
func (g GoFrontend) Change(root, rev string, c *Change, added map[string][]int) error {
	for _, name := range c.Files {
		if !g.Covers(name) {
			continue
		}
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		path := filepath.Join(root, name)
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, source, parser.ParseComments)
		if err != nil {
			continue
		}
		lines := strings.Split(string(source), "\n")
		touched := added[name]

		ast.Inspect(file, func(n ast.Node) bool {
			switch decl := n.(type) {
			case *ast.FuncDecl:
				line := fset.Position(decl.Pos()).Line
				end := fset.Position(decl.End()).Line
				name := decl.Name.Name
				// A test is judged by what it asserts, so a change anywhere
				// inside one is a change to the test.
				if isTest(name) {
					if !touchedBetween(touched, line, end) {
						return true
					}
					c.Tests = append(c.Tests, Function{
						Name: name, File: relative(root, path), Line: line,
						Body: text(lines, line, end),
					})
					return true
				}
				// A name is new when its declaration is. Work inside a body
				// changes what a function does, not what it is called.
				if !slices.Contains(touched, line) {
					return true
				}
				c.Symbols = append(c.Symbols, Symbol{
					Name: name, Kind: "func", Doc: doc(decl.Doc),
					File: relative(root, path), Line: line,
					Exported: ast.IsExported(name), Signature: strings.TrimSpace(lines[line-1]),
				})
			case *ast.TypeSpec:
				line := fset.Position(decl.Pos()).Line
				if !slices.Contains(touched, line) {
					return true
				}
				c.Symbols = append(c.Symbols, Symbol{
					Name: decl.Name.Name, Kind: "type", File: relative(root, path), Line: line,
					Exported: ast.IsExported(decl.Name.Name), Signature: strings.TrimSpace(lines[line-1]),
				})
			case *ast.ValueSpec:
				for _, ident := range decl.Names {
					line := fset.Position(ident.Pos()).Line
					if !slices.Contains(touched, line) {
						continue
					}
					c.Symbols = append(c.Symbols, Symbol{
						Name: ident.Name, Kind: "value", File: relative(root, path), Line: line,
						Exported: ast.IsExported(ident.Name), Signature: strings.TrimSpace(lines[line-1]),
					})
				}
			}
			return true
		})

		for _, group := range file.Comments {
			for _, comment := range group.List {
				line := fset.Position(comment.Pos()).Line
				if !slices.Contains(touched, line) {
					continue
				}
				c.Comments = append(c.Comments, Located{
					Text: strings.TrimSpace(strings.TrimPrefix(comment.Text, "//")),
					File: relative(root, path), Line: line,
				})
			}
		}
	}
	return nil
}

// Whole reads every declaration in the repository. It is built by parsing
// rather than by searching: a pattern over lines misses an indented constant
// inside a block, which is exactly where a duplicated fact tends to live.
func (GoFrontend) Whole(root, rev string) ([]Declared, error) {
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

// isTest reports whether a function is one the testing package runs.
func isTest(name string) bool {
	return strings.HasPrefix(name, "Test") || strings.HasPrefix(name, "Fuzz") || strings.HasPrefix(name, "Benchmark")
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

func doc(group *ast.CommentGroup) string {
	if group == nil {
		return ""
	}
	return strings.TrimSpace(group.Text())
}
