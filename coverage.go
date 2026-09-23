package main

// Two things about a change are visible only against the whole repository:
// whether anything refers to what it adds, and whether it added tests where
// the repository keeps them. Both are counted over the tree in memory,
// which is the same on every system the tool runs on.

import (
	"fmt"
	"maps"
	"slices"
	"strings"
)

// checkUnreferenced reports a new declaration nothing in the repository
// refers to: not the change, not the rest of the tree. It is written and
// waiting, and what waits drifts. The name is searched as a whole word
// over every text file, so a use from a template or a script counts.
func checkUnreferenced(c *Change) []Finding {
	var fresh []Symbol
	for _, s := range c.Symbols {
		if isTestFile(s.File) || s.Kind == "field" || unsearchable[s.Name] || calledByTheRuntime(s) {
			continue
		}
		fresh = append(fresh, s)
	}
	if len(fresh) == 0 {
		return nil
	}
	tree, err := treeAt(c.root, c.rev)
	if err != nil {
		return nil
	}
	sources, err := tree.Sources()
	if err != nil {
		return nil
	}
	// One finding per file, naming what it declares and nothing refers
	// to: a change that adds twenty unused values is one conversation.
	unused := map[string][]Symbol{}
	for _, s := range fresh {
		if referenced(s, sources) {
			continue
		}
		unused[s.File] = append(unused[s.File], s)
	}
	var out []Finding
	for _, file := range slices.Sorted(maps.Keys(unused)) {
		names := make([]string, 0, len(unused[file]))
		for _, s := range unused[file] {
			names = append(names, s.Name)
		}
		shown := names
		if len(shown) > 8 {
			shown = append(shown[:8], fmt.Sprintf("and %d more", len(names)-8))
		}
		out = append(out, Finding{
			Job: "static", Rule: "new-symbol-unreferenced", Severity: Consider,
			File: file, Line: unused[file][0].Line, Symbol: names[0],
			Message: fmt.Sprintf("nothing in the repository refers to %s but the declaration%s in %s; code written for a caller that does not exist yet is a guess about what the caller will need", strings.Join(shown, ", "), plural(len(names)), file),
			Fix:     "use it, or leave it out until something does",
		})
	}
	return out
}

// unsearchable are the names the language calls rather than the code, and
// names too short to search for.
var unsearchable = map[string]bool{"main": true, "init": true, "TestMain": true, "_": true, "default": true}

// runtimeMethods are the methods the standard library and its encoders call
// through an interface or by reflection, so that nothing in the repository
// names them and they are referenced all the same. Measured: MarshalJSON
// and UnmarshalJSON on a bundle's appearance were the first false report.
var runtimeMethods = set(`String Error Format GoString MarshalJSON UnmarshalJSON MarshalText UnmarshalText
	MarshalBinary UnmarshalBinary MarshalYAML UnmarshalYAML GobEncode GobDecode Len Less Swap Read Write
	Close Seek ReadFrom WriteTo ServeHTTP Scan Value Is As Unwrap Compare Equal Hash`)

// calledByTheRuntime is whether a symbol is called by something outside the
// repository's text: a method an encoder or interface reaches for, or a
// function cgo exports to the host under //export.
func calledByTheRuntime(s Symbol) bool {
	if s.Kind == "func" && runtimeMethods[s.Name] {
		return true
	}
	// The export directive is the last line of the doc comment, after
	// whatever prose the function has.
	if strings.HasSuffix(s.File, ".go") {
		for _, line := range strings.Split(s.Doc, "\n") {
			if strings.TrimSpace(line) == "export "+s.Name {
				return true
			}
		}
	}
	return false
}

// referenced is whether the name appears as a whole word anywhere but on
// its own declaration line or in a comment. A Go doc comment opens with
// the name it documents, and a comment is not a caller.
func referenced(s Symbol, sources map[string][]byte) bool {
	if len(s.Name) < 2 {
		return true // Too short to search for honestly.
	}
	for file, data := range sources {
		text := string(data)
		offset := 0
		for {
			i := strings.Index(text[offset:], s.Name)
			if i < 0 {
				break
			}
			at := offset + i
			offset = at + len(s.Name)
			if !wordBoundary(text, at, len(s.Name)) {
				continue
			}
			if file == s.File && lineOf(text, at) == s.Line {
				continue
			}
			if inComment(text, at) {
				continue
			}
			return true
		}
	}
	return false
}

// wordBoundary is whether the match at i of length n is bounded by
// non-identifier characters on both sides.
func wordBoundary(text string, i, n int) bool {
	before := i == 0 || !identChar(text[i-1])
	after := i+n >= len(text) || !identChar(text[i+n])
	return before && after
}

func identChar(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// inComment is whether the offset sits on a line that is a comment by the
// shapes the tool's languages share, or after a line comment's opening.
func inComment(text string, offset int) bool {
	start := strings.LastIndexByte(text[:offset], '\n') + 1
	line := text[start:offset]
	if isCommentLine(strings.TrimSpace(line + text[offset:min(offset+1, len(text))])) {
		return true
	}
	return strings.Contains(line, "//") || strings.Contains(line, "/*")
}

// lineOf is the 1-based line the offset falls on.
func lineOf(text string, offset int) int {
	return 1 + strings.Count(text[:offset], "\n")
}

// testFloorLines is the size of change, in lines added to code that is not
// a test, from which a change owes a test where the repository keeps them.
const testFloorLines = 50

// checkCodeWithoutTests reports a change that adds a body of code to a
// repository that has tests, and touches none of them. History's coupling
// check names the pair when there is a pair; this is the general case.
func checkCodeWithoutTests(c *Change) []Finding {
	added, _ := diffSides(c.Diff)
	lines := 0
	for file, l := range added {
		if isCodeFile(file) && !isTestFile(file) {
			lines += len(l)
		}
	}
	if lines < testFloorLines {
		return nil
	}
	for _, f := range c.Files {
		if isTestFile(f) {
			return nil
		}
	}
	tree, err := treeAt(c.root, c.rev)
	if err != nil {
		return nil
	}
	files, err := tree.Files()
	if err != nil {
		return nil
	}
	tested := 0
	for _, f := range files {
		if isTestFile(f) {
			tested++
		}
	}
	if tested == 0 {
		return nil // A repository without tests is not asked to start here.
	}
	return []Finding{{
		Job: "static", Rule: "code-without-tests", Severity: Consider,
		Message: fmt.Sprintf("the change adds %d lines of code and touches no test, in a repository that keeps %d test files; what the change does is asserted nowhere", lines, tested),
		Fix:     "add or extend the test that would fail without this change",
	}}
}
