package main

// Python and Rust are read through ast-grep by node kind rather than by
// pattern: a function is whatever the grammar calls a function, wherever
// it sits, and the name is read out of the match. One frontend serves both,
// told which grammar, which kinds, and how a name and its visibility are
// read.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// kindRule is one declaration shape: the ast-grep rule that matches it, the
// kind the tool reports it as, and the expression that reads its name out
// of the match text.
type kindRule struct {
	id   string
	kind string
	rule string
	name *regexp.Regexp
	test bool
}

// KindFrontend reads one language by its grammar's node kinds.
type KindFrontend struct {
	name     string
	language string
	exts     []string
	rules    []kindRule
	// exported reads a declaration's visibility from its text.
	exported func(text, name string) bool
	// pkg reads the package or module a file declares, or nothing.
	pkg func(path string, lines []string) string
}

func (f *KindFrontend) Name() string { return f.name }

func (f *KindFrontend) Covers(path string) bool {
	for _, ext := range f.exts {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	return false
}

func (*KindFrontend) Features() Features {
	return FeatSymbols | FeatTests | FeatComments | FeatIndex
}

// pythonFrontend reads Python: module-level functions, classes and
// assignments, and any function named test_. A leading underscore is the
// language's whole notion of private.
func pythonFrontend() *KindFrontend {
	top := "  not:\n    inside:\n      any:\n        - kind: function_definition\n        - kind: class_definition\n      stopBy: end\n"
	return &KindFrontend{
		name: "python", language: "Python", exts: []string{".py"},
		rules: []kindRule{
			{"py-func", "func", "  kind: function_definition\n" + top, regexp.MustCompile(`^\s*(?:async\s+)?def\s+(\w+)`), false},
			{"py-class", "type", "  kind: class_definition\n" + top, regexp.MustCompile(`^\s*class\s+(\w+)`), false},
			{"py-value", "value", "  kind: assignment\n  inside:\n    kind: expression_statement\n    inside:\n      kind: module\n", regexp.MustCompile(`^\s*(\w+)\s*(?::[^=]*)?=`), false},
			{"py-test", "func", "  kind: function_definition\n  has:\n    field: name\n    regex: ^test_\n", regexp.MustCompile(`^\s*(?:async\s+)?def\s+(\w+)`), true},
		},
		exported: func(_, name string) bool { return !strings.HasPrefix(name, "_") },
		pkg:      func(string, []string) string { return "" },
	}
}

// rustFrontend reads Rust: functions wherever they are declared, impl
// methods included, the type items, constants and statics, and any function
// a test attribute precedes. pub is the whole notion of exported.
func rustFrontend() *KindFrontend {
	return &KindFrontend{
		name: "rust", language: "Rust", exts: []string{".rs"},
		rules: []kindRule{
			{"rs-func", "func", "  kind: function_item\n", regexp.MustCompile(`\bfn\s+(\w+)`), false},
			{"rs-type", "type", "  any:\n    - kind: struct_item\n    - kind: enum_item\n    - kind: type_item\n    - kind: trait_item\n", regexp.MustCompile(`\b(?:struct|enum|type|trait)\s+(\w+)`), false},
			{"rs-value", "value", "  any:\n    - kind: const_item\n    - kind: static_item\n", regexp.MustCompile(`\b(?:const|static)\s+(?:mut\s+)?(\w+)`), false},
			{"rs-test", "func", "  kind: function_item\n  follows:\n    kind: attribute_item\n    regex: '^#\\[[\\w:]*test(\\(|\\])'\n", regexp.MustCompile(`\bfn\s+(\w+)`), true},
		},
		exported: func(text, _ string) bool { return strings.HasPrefix(strings.TrimSpace(text), "pub") },
		pkg:      func(string, []string) string { return "" },
	}
}

// writeRules emits the frontend's rules for ast-grep to read.
func (f *KindFrontend) writeRules(dir string) error {
	for _, r := range f.rules {
		body := fmt.Sprintf("id: %s\nlanguage: %s\nseverity: info\nrule:\n%s", r.id, f.language, r.rule)
		if err := os.WriteFile(filepath.Join(dir, r.id+".yml"), []byte(body), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// read maps the matches back onto declarations: one per line, the test
// rule's reading preferred where a function is both.
func (f *KindFrontend) read(matches []grepMatch) []kindMatch {
	byLine := map[string]kindMatch{}
	for _, m := range matches {
		var rule kindRule
		for _, r := range f.rules {
			if r.id == m.Rule {
				rule = r
			}
		}
		if rule.name == nil {
			continue
		}
		sub := rule.name.FindStringSubmatch(m.Text)
		if sub == nil {
			continue
		}
		key := fmt.Sprintf("%s:%d", m.File, m.Range.Start.Line)
		if old, ok := byLine[key]; ok && old.Test && !rule.test {
			continue
		}
		byLine[key] = kindMatch{File: m.File, Line: m.Range.Start.Line + 1, Name: sub[1], Kind: rule.kind, Test: rule.test, Text: m.Text}
	}
	out := make([]kindMatch, 0, len(byLine))
	for _, m := range byLine {
		out = append(out, m)
	}
	// In file and line order, so that what is read is the same on every
	// run.
	slices.SortFunc(out, func(a, b kindMatch) int {
		if c := strings.Compare(a.File, b.File); c != 0 {
			return c
		}
		return a.Line - b.Line
	})
	return out
}

// kindMatch is one declaration as read out of a match.
type kindMatch struct {
	File, Name, Kind, Text string
	Line                   int
	Test                   bool
}

// Change appends the declarations, tests and prose the added lines of the
// change's files in this language introduce.
func (f *KindFrontend) Change(root, rev string, c *Change, added map[string][]int) error {
	var covered []string
	for _, name := range c.Files {
		if f.Covers(name) {
			covered = append(covered, name)
		}
	}
	matches, err := scanWith(covered, root, rev, f.writeRules)
	if err != nil {
		return err
	}
	sources := map[string][]string{}
	touched := map[string]map[int]bool{}
	for _, name := range covered {
		source, err := at(root, rev, name)
		if err != nil {
			continue
		}
		sources[name] = strings.Split(string(source), "\n")
		touched[name] = map[int]bool{}
		for _, line := range added[name] {
			touched[name][line] = true
		}
		c.Comments = append(c.Comments, commentProse(source, name, added[name])...)
	}
	for _, m := range f.read(matches) {
		lines := sources[m.File]
		if m.Test {
			// A test is judged by what it asserts, so a change anywhere
			// inside one is a change to the test.
			end := m.Line + strings.Count(m.Text, "\n")
			if !touchedBetween(added[m.File], m.Line, end) {
				continue
			}
			c.Tests = append(c.Tests, Function{Name: m.Name, File: m.File, Line: m.Line, Body: m.Text})
			continue
		}
		if !touched[m.File][m.Line] {
			continue
		}
		signature := ""
		if m.Line-1 < len(lines) {
			signature = strings.TrimSpace(lines[m.Line-1])
		}
		symbol := Symbol{
			Name: m.Name, Kind: m.Kind, Doc: docAbove(lines, m.Line),
			File: m.File, Line: m.Line,
			Exported: f.exported(m.Text, m.Name), Signature: signature,
			Package: f.pkg(m.File, lines),
		}
		if m.Kind == "func" {
			symbol.Body = m.Text
		}
		c.Symbols = append(c.Symbols, symbol)
	}
	return nil
}

// Whole reads every declaration in the repository's files in this
// language, tests left out, so a new name can be checked against the ones
// it may duplicate.
func (f *KindFrontend) Whole(root, rev string) ([]Declared, error) {
	tree, err := treeAt(root, rev)
	if err != nil {
		return nil, err
	}
	tracked, err := tree.Files()
	if err != nil {
		return nil, err
	}
	var files []string
	for _, name := range tracked {
		if f.Covers(name) {
			files = append(files, name)
		}
	}
	matches, err := scanWith(files, root, rev, f.writeRules)
	if err != nil {
		return nil, err
	}
	var index []Declared
	for _, m := range f.read(matches) {
		if m.Test {
			continue
		}
		text := strings.SplitN(m.Text, "\n", 2)[0]
		declared := Declared{Name: m.Name, Kind: m.Kind, File: m.File, Line: m.Line, Text: text}
		if m.Kind == "func" {
			declared.Body = m.Text
		}
		index = append(index, declared)
	}
	return index, nil
}
