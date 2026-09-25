// review-go prints the declarations, imports and comments of the Go files it
// is given, as JSON, using Go's own parser. It is the Go frontend as a
// sidecar, so a reviewer written in another language reads Go the way this
// one does. One line per invocation:
//
//	review-go file.go ... > decls.json
//
// where the JSON is {"files":[{"name":"a.go","package":"main",
// "imports":["fmt"],"decls":[{"name":"main","kind":"func","line":7,
// "end_line":9,"exported":false,"test":false,"local":false,
// "text":"func main() {","doc":"..."}],"comments":[{"line":5,"text":"..."}]}]}
//
// Kinds are func, type, field, const and var. A method is a func under its
// own name. A test is a func the testing package would run. A local
// declaration sits inside a function body. A file that does not parse is
// reported with its error and nothing else, so the caller can tell a file
// with no declarations from one it could not read. Build it and put it on
// the path:
//
//	go build -o ~/go/bin/review-go ./sidecar/gofront
package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strings"
)

// Decl is one declaration as the sidecar reports it. The shape is the Odin
// sidecar's, with what Go adds: a kind that tells const from var, and
// whether the declaration is local to a function.
type Decl struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Line     int    `json:"line"`
	EndLine  int    `json:"end_line"`
	Exported bool   `json:"exported"`
	Test     bool   `json:"test"`
	Local    bool   `json:"local"`
	Text     string `json:"text"`
	Doc      string `json:"doc"`
}

// Comment is one comment, located by its first line, with the marker
// stripped and the text trimmed. Indent is how far the text sat from the
// marker, in columns, which is what sets a documented example apart from
// code left behind as a comment.
type Comment struct {
	Line   int    `json:"line"`
	Text   string `json:"text"`
	Indent int    `json:"indent"`
}

// indentOf is the width of the leading whitespace, a tab standing for
// four columns.
func indentOf(text string) int {
	columns := 0
	for _, r := range text {
		switch r {
		case '\t':
			columns += 4
		case ' ':
			columns++
		default:
			return columns
		}
	}
	return columns
}

// File is what one Go file declares.
type File struct {
	Name     string    `json:"name"`
	Package  string    `json:"package,omitempty"`
	Imports  []string  `json:"imports"`
	Decls    []Decl    `json:"decls"`
	Comments []Comment `json:"comments"`
	Error    string    `json:"error,omitempty"`
}

type Output struct {
	Files []File `json:"files"`
}

func main() {
	out := Output{Files: []File{}}
	for _, arg := range os.Args[1:] {
		source, err := os.ReadFile(arg)
		if err != nil {
			out.Files = append(out.Files, File{Name: arg, Imports: []string{}, Decls: []Decl{}, Comments: []Comment{}, Error: err.Error()})
			continue
		}
		out.Files = append(out.Files, readFile(arg, source))
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "review-go: %v\n", err)
		os.Exit(1)
	}
	os.Stdout.Write(data)
}

// readFile parses one file and lists everything in it a reviewer asks
// about. Every declaration is reported, tests and locals included; what to
// keep is the caller's decision.
func readFile(name string, source []byte) File {
	result := File{Name: name, Imports: []string{}, Decls: []Decl{}, Comments: []Comment{}}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, source, parser.ParseComments)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Package = file.Name.Name
	lines := strings.Split(string(source), "\n")
	line := func(pos token.Pos) int { return fset.Position(pos).Line }
	textAt := func(pos token.Pos) string {
		n := line(pos)
		if n < 1 || n > len(lines) {
			return ""
		}
		return strings.TrimSpace(lines[n-1])
	}
	for _, imported := range file.Imports {
		result.Imports = append(result.Imports, importName(imported))
	}

	// A declaration is local when it sits inside a function body. Inspect
	// gives no leaving event, so the bodies still open are kept by their
	// end, and closed as soon as a node starts past it.
	var open []token.Pos
	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		for len(open) > 0 && n.Pos() >= open[len(open)-1] {
			open = open[:len(open)-1]
		}
		switch d := n.(type) {
		case *ast.FuncDecl:
			name := d.Name.Name
			result.Decls = append(result.Decls, Decl{
				Name: name, Kind: "func", Line: line(d.Pos()), EndLine: line(d.End()),
				Exported: ast.IsExported(name), Test: isTest(name),
				Text: textAt(d.Pos()), Doc: doc(d.Doc),
			})
			if d.Body != nil {
				open = append(open, d.Body.End())
			}
		case *ast.FuncLit:
			open = append(open, d.Body.End())
		case *ast.GenDecl:
			result.Decls = append(result.Decls, specs(d, len(open) > 0, line, textAt)...)
		}
		return true
	})

	for _, group := range file.Comments {
		for _, comment := range group.List {
			body := strings.TrimPrefix(comment.Text, "//")
			result.Comments = append(result.Comments, Comment{
				Line:   line(comment.Pos()),
				Indent: indentOf(body),
				Text:   strings.TrimSpace(body),
			})
		}
	}
	return result
}

// specs lists what a const, var or type declaration declares. A struct's
// fields are declarations too, and a field is where a restated fact often
// sits.
func specs(d *ast.GenDecl, local bool, line func(token.Pos) int, textAt func(token.Pos) string) []Decl {
	var decls []Decl
	for _, spec := range d.Specs {
		switch s := spec.(type) {
		case *ast.TypeSpec:
			decls = append(decls, Decl{
				Name: s.Name.Name, Kind: "type", Line: line(s.Pos()), EndLine: line(s.End()),
				Exported: ast.IsExported(s.Name.Name), Local: local,
				Text: textAt(s.Pos()), Doc: docOf(s.Doc, d),
			})
			structure, ok := s.Type.(*ast.StructType)
			if !ok {
				continue
			}
			for _, field := range structure.Fields.List {
				for _, ident := range field.Names {
					decls = append(decls, Decl{
						Name: ident.Name, Kind: "field", Line: line(ident.Pos()), EndLine: line(field.End()),
						Exported: ast.IsExported(ident.Name), Local: local,
						Text: textAt(ident.Pos()), Doc: doc(field.Doc),
					})
				}
			}
		case *ast.ValueSpec:
			for _, ident := range s.Names {
				decls = append(decls, Decl{
					Name: ident.Name, Kind: kindOf(d.Tok), Line: line(ident.Pos()), EndLine: line(s.End()),
					Exported: ast.IsExported(ident.Name), Local: local,
					Text: textAt(ident.Pos()), Doc: docOf(s.Doc, d),
				})
			}
		}
	}
	return decls
}

// importName is the name an import binds in the file: its alias where it
// has one, else the last element of its path.
//
//review:ignore duplicate-body the sidecar is one self-contained package main, and the Go tool keeps its own reading until it reads Go through this one
func importName(spec *ast.ImportSpec) string {
	if spec.Name != nil {
		return spec.Name.Name
	}
	path := strings.Trim(spec.Path.Value, `"`)
	if i := strings.LastIndex(path, "/"); i >= 0 {
		path = path[i+1:]
	}
	return path
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

// docOf is a spec's own doc, or its group's when the group declares only
// it: `// Doc` above `type X struct` documents X, not a parenthesis.
func docOf(own *ast.CommentGroup, group *ast.GenDecl) string {
	if text := doc(own); text != "" {
		return text
	}
	if len(group.Specs) == 1 {
		return doc(group.Doc)
	}
	return ""
}
