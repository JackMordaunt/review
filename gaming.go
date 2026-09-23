package main

// These checks hold the review to itself. A change can pass every job by
// dismissing what they find or by deleting the tests that would have
// failed, and no narrow reader would say a word about it: each job reads
// only its own criteria, and neither mechanism is one job's subject. Both
// are the person reviewing's decision to make, not the change's progress,
// so they are measured here, where nothing is asked of a model and nothing
// can be talked around.

import (
	"fmt"
	"maps"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// checkSuppressionAdded reports what the change dismisses before the
// readers run — the criteria name the rule suppression-added. A finding
// dismissed by the same change that produced it is the reviewer's decision
// to accept, not the change's progress; left unmeasured, a reading can be
// iterated into silence one ignore at a time. It is reported as one finding
// without a file, so it cannot be dismissed in turn — a check that polices
// the dismissing must not be dismissible.
func checkSuppressionAdded(c *Change) []Finding {
	added, _ := diffSides(c.Diff)
	var spots []string
	for _, file := range slices.Sorted(maps.Keys(added)) {
		if !isCodeFile(file) {
			continue
		}
		for _, l := range added[file] {
			m := ignore.FindStringSubmatch(l.Text)
			if m == nil || !ruleID.MatchString(m[1]) {
				continue
			}
			spots = append(spots, fmt.Sprintf("%s:%d (%s)", file, l.Line, m[1]))
		}
	}
	if len(spots) == 0 {
		return nil
	}
	return []Finding{{
		Job:      "static",
		Rule:     "suppression-added",
		Severity: MustFix,
		Message: fmt.Sprintf(
			"the change adds its own dismissal%s: %s; a dismissal is a decision for the person reviewing the change, and a review that dismisses itself cannot be failed",
			plural(len(spots)), strings.Join(spots, "; ")),
		Fix: "correct what the dismissal covers; a dismissal belongs to the person reviewing, who accepts it deliberately",
	}}
}

// isCodeFile reports whether a path is a place code could live — which is
// where a dismissal could work, and where a reader could plausibly exist.
// The prose and data formats are where the mechanism gets documented and
// where configuration lives, not where findings are made.
func isCodeFile(path string) bool {
	base := filepath.Base(path)
	switch base {
	case ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig",
		"Makefile", "Dockerfile", "LICENSE", "CODEOWNERS":
		return false
	}
	for _, ext := range []string{
		".md", ".mdx", ".txt", ".rst", ".adoc", ".json", ".yaml", ".yml",
		".toml", ".lock", ".sum", ".mod", ".html", ".htm", ".css", ".svg",
		".xml",
	} {
		if strings.HasSuffix(base, ext) {
			return false
		}
	}
	return true
}

// ruleID is what a dismissal's rule id has to look like. The prose that
// documents the mechanism writes placeholders (<rule>) and quoted examples,
// which match the ignore pattern but dismiss nothing.
var ruleID = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// goTest is a test function's declaration, as a removed line carries it.
var goTest = regexp.MustCompile(`^func ((?:Test|Benchmark|Fuzz)[A-Za-z0-9_]+)\(`)

// jsTestCall is a test's registration in the JavaScript and TypeScript
// shapes — Node, Bun, Deno and the Jest family — with the skipping and
// focusing modifiers read through.
var jsTestCall = regexp.MustCompile(`^(?:Deno\.test|test|describe|it)(?:\.(?:skip|only|todo|fails|failing|ignore|concurrent|serial))*\(`)

// isTestFile reports whether a path is one a test runner reads, in any of the
// naming habits the tool's languages have: a marker in the name, or a tests
// directory. A Rust unit test sits in the source file beside the code, and
// that file is not a test file; an integration test under tests/ is.
func isTestFile(path string) bool {
	base := filepath.Base(path)
	for _, marker := range []string{"_test.", ".test.", ".spec."} {
		if strings.Contains(base, marker) {
			return true
		}
	}
	if strings.HasSuffix(base, ".py") && (strings.HasPrefix(base, "test_") || strings.HasSuffix(base, "_test.py")) {
		return true
	}
	for dir := range strings.SplitSeq(filepath.ToSlash(filepath.Dir(path)), "/") {
		if dir == "tests" || dir == "__tests__" || dir == "test" {
			return true
		}
	}
	return false
}

// pyTest is a Python test's declaration, as a removed line carries it.
var pyTest = regexp.MustCompile(`^(?:async\s+)?def (test_\w+)\(`)

// rsTestAttribute is the attribute that makes the Rust function after it a
// test; rsFn is that function's declaration.
var (
	rsTestAttribute = regexp.MustCompile(`^#\[[\w:]*test(\(|\])`)
	rsFn            = regexp.MustCompile(`^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn (\w+)\(`)
)

// checkDeletedTests reports the tests a change deletes. The tests job reads
// the tests a change adds or alters, and a test is never heard from again
// once deleted, so deletion is where a test the reading would have failed
// goes to pass the review. A test the change also adds under a name made of
// the same words is a rename, and is spared. The shapes read here are a Go
// test function's and a JS test registration's; tests in other languages
// are not named by anything this package reads.
func checkDeletedTests(c *Change) []Finding {
	added, removed := diffSides(c.Diff)
	spoken := addedTestNames(added)
	var findings []Finding
	for _, file := range slices.Sorted(maps.Keys(removed)) {
		if !isTestFile(file) && !strings.HasSuffix(file, ".rs") {
			continue
		}
		var names []string
		seen := map[string]bool{}
		for i, text := range removed[file] {
			name := removedTestName(text)
			if strings.HasSuffix(file, ".rs") {
				// A Rust test is the function after the attribute, and
				// only that; a deleted function without one is not a test.
				name = ""
				if rsTestAttribute.MatchString(strings.TrimSpace(text)) && i+1 < len(removed[file]) {
					if m := rsFn.FindStringSubmatch(strings.TrimSpace(removed[file][i+1])); m != nil {
						name = m[1]
					}
				}
			}
			if name == "" || seen[name] {
				continue
			}
			seen[name] = true
			if !covered(name, spoken) {
				names = append(names, name)
			}
		}
		if len(names) == 0 {
			continue
		}
		shown := names
		if len(shown) > 8 {
			shown = append(shown[:8], fmt.Sprintf("and %d more", len(names)-8))
		}
		var listed []string
		for _, name := range shown {
			listed = append(listed, fmt.Sprintf("%q", name))
		}
		findings = append(findings, Finding{
			Job:      "static",
			Rule:     "test-deleted",
			Severity: MustFix,
			File:     file,
			Symbol:   names[0],
			Message: fmt.Sprintf(
				"the change deletes the test%s %s from %s; a deleted test cannot fail again, so deletion is where a failing test goes to pass the review",
				plural(len(names)), strings.Join(listed, ", "), file),
			Fix: fmt.Sprintf("restore the test, or dismiss it where a reader can read why: a review:ignore comment naming test-deleted, with the reason, in %s", file),
		})
	}
	return findings
}

// removedTestName reads the name of a deleted test out of its removed line,
// in the shapes the tool's languages write tests in.
func removedTestName(text string) string {
	trimmed := strings.TrimLeft(text, " \t")
	if m := goTest.FindStringSubmatch(trimmed); m != nil {
		return m[1]
	}
	if m := pyTest.FindStringSubmatch(trimmed); m != nil {
		return m[1]
	}
	if loc := jsTestCall.FindStringSubmatchIndex(trimmed); loc != nil {
		return readQuoted(strings.TrimLeft(trimmed[loc[1]:], " \t"))
	}
	return ""
}

// readQuoted reads the string literal a JS test registration is named by,
// from the text that follows its opening parenthesis.
func readQuoted(text string) string {
	if len(text) == 0 {
		return ""
	}
	q := text[0]
	if q != '"' && q != '\'' && q != '`' {
		return ""
	}
	if end := strings.IndexByte(text[1:], q); end >= 0 {
		return text[1 : 1+end]
	}
	return ""
}

// addedTestNames collects the names of the tests a change adds, read with
// the same shapes the removed side is read with, so that a rename is not
// read as a deletion.
func addedTestNames(added map[string][]diffLine) []string {
	seen := map[string]bool{}
	for _, lines := range added {
		for _, l := range lines {
			trimmed := strings.TrimLeft(l.Text, " \t")
			if m := goTest.FindStringSubmatch(trimmed); m != nil {
				seen[m[1]] = true
			} else if m := pyTest.FindStringSubmatch(trimmed); m != nil {
				seen[m[1]] = true
			} else if m := rsFn.FindStringSubmatch(trimmed); m != nil {
				seen[m[1]] = true
			} else if loc := jsTestCall.FindStringSubmatchIndex(trimmed); loc != nil {
				if name := readQuoted(strings.TrimLeft(trimmed[loc[1]:], " \t")); name != "" {
					seen[name] = true
				}
			}
		}
	}
	return slices.Sorted(maps.Keys(seen))
}

// covered reports whether a deleted test's name is spoken for by a test the
// change adds: every word of the old name is in a new one, which is what a
// rename or a re-anchored test looks like.
func covered(deleted string, spoken []string) bool {
	want := words(deleted)
	if len(want) == 0 {
		return false
	}
	for _, name := range spoken {
		have := words(name)
		saysAll := true
		for _, w := range want {
			if !slices.Contains(have, w) {
				saysAll = false
				break
			}
		}
		if saysAll {
			return true
		}
	}
	return false
}

// words breaks a test's name into its lowercased words: camel humps and
// underscores for the Go shapes, spaces for the strings the JavaScript
// shapes are named by, with the runner's own prefixes and short leftovers
// left out.
func words(name string) []string {
	var out []string
	for _, part := range split(name) {
		for _, piece := range strings.Fields(part) {
			piece = strings.ToLower(piece)
			if len(piece) < 3 {
				continue
			}
			switch piece {
			case "test", "benchmark", "fuzz", "skip", "only", "todo", "fails":
				continue
			}
			out = append(out, piece)
		}
	}
	return out
}

// plural is the s a count takes when it is not one.
func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
