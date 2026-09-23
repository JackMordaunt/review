package main

// What a change leaves behind by accident has a shape: a debugger statement,
// a task marker nobody is named on, code kept as a comment, an error caught
// and dropped. Each is a pattern over the lines the change adds, and none
// needs a reading to name.

import (
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
)

// debugMarkers are the calls and statements that exist to be removed before
// a change is done, by language. Ordinary printing is not here: a command's
// output and a debug print share a function, and only the author knows
// which is which.
var debugMarkers = []struct {
	suffixes []string
	pattern  *regexp.Regexp
	severity Severity
}{
	{[]string{".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"}, regexp.MustCompile(`^\s*debugger\s*;?\s*$`), Consider},
	{[]string{".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"}, regexp.MustCompile(`\bconsole\.(log|debug|trace)\(`), Note},
	{[]string{".py"}, regexp.MustCompile(`\b(breakpoint\(\)|pdb\.set_trace\(\)|ipdb\.set_trace\(\))`), Consider},
	{[]string{".rs"}, regexp.MustCompile(`\bdbg!\(`), Consider},
	{[]string{".go"}, regexp.MustCompile(`\b(spew\.Dump|litter\.Dump|pp\.Print)\(`), Consider},
	{[]string{".rb"}, regexp.MustCompile(`\b(binding\.pry|byebug|debugger)\b`), Consider},
	{nil, regexp.MustCompile(`\b(Printf|Println|Print|log|print|debug)\(\s*["'](DEBUG|XXX|HERE|>>>)`), Consider},
}

// checkDebugLeftovers reports the debugging a change adds and did not
// remove.
func checkDebugLeftovers(c *Change) []Finding {
	added, _ := diffSides(c.Diff)
	var out []Finding
	for _, file := range slices.Sorted(maps.Keys(added)) {
		if !isCodeFile(file) {
			continue
		}
		for _, l := range added[file] {
			for _, m := range debugMarkers {
				if m.suffixes != nil && !hasSuffix(file, m.suffixes) {
					continue
				}
				if !m.pattern.MatchString(l.Text) {
					continue
				}
				out = append(out, Finding{
					Job: "static", Rule: "debug-leftover", Severity: m.severity,
					File: file, Line: l.Line,
					Message: fmt.Sprintf("the change adds debugging output: %s", strings.TrimSpace(l.Text)),
					Fix:     "remove it before the change is done",
				})
				break
			}
		}
	}
	return out
}

func hasSuffix(path string, suffixes []string) bool {
	for _, s := range suffixes {
		if strings.HasSuffix(path, s) {
			return true
		}
	}
	return false
}

var (
	// taskMarker is a comment that names work left undone.
	taskMarker = regexp.MustCompile(`\b(TODO|FIXME|XXX|HACK)\b`)
	// taskReference is what makes a task marker answerable: an issue
	// number, a ticket key, a link, or a name in parentheses.
	taskReference = regexp.MustCompile(`#\d+|\b[A-Z][A-Z0-9]+-\d+\b|https?://|\(\w+\)`)
)

// checkTodos reports a task marker the change adds with nothing to find it
// by again: no issue, no ticket, no name. Unreferenced, it is a promise the
// log will not keep.
func checkTodos(c *Change) []Finding {
	var out []Finding
	for _, comment := range c.Comments {
		if !taskMarker.MatchString(comment.Text) || taskReference.MatchString(comment.Text) {
			continue
		}
		out = append(out, Finding{
			Job: "static", Rule: "todo-without-reference", Severity: Note,
			File: comment.File, Line: comment.Line,
			Message: fmt.Sprintf("the change adds a task marker nothing refers to: %q", firstLine(comment.Text)),
			Fix:     "name the issue or the person, or do the work now",
		})
	}
	return out
}

var (
	// strongCode is a comment line that is code beyond doubt: an
	// assignment operator, a call closed and terminated, a closing brace
	// terminated, an arrow function.
	strongCode = regexp.MustCompile(`:=|\);\s*$|\};\s*$|=>|^\s*\}\s*else\s*\{`)
	// weakCode is a comment line shaped like a statement, which two in a
	// row make into commented-out code.
	weakCode = regexp.MustCompile(`^(if|for|while|return|func|fn|def|import|const|let|var|switch|case|else|try|catch|package|use|pub|proc|struct|type|class|await|export)\b.*[({=:;]\s*$|^[\w.]+\(.*\)\s*;?\s*$|[;{}]\s*$`)
)

// codeLike is whether a comment line reads as code, and how surely.
func codeLike(text string) (strong, weak bool) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" || directive(trimmed) {
		return false, false
	}
	return strongCode.MatchString(trimmed), weakCode.MatchString(trimmed)
}

// checkCommentedCode reports code the change keeps as comments. A run of
// consecutive comment lines is one candidate; it is reported when two of
// its lines are shaped like statements, or one is code beyond doubt.
func checkCommentedCode(c *Change) []Finding {
	var out []Finding
	byFile := map[string][]Located{}
	for _, comment := range c.Comments {
		byFile[comment.File] = append(byFile[comment.File], comment)
	}
	for _, file := range slices.Sorted(maps.Keys(byFile)) {
		comments := byFile[file]
		slices.SortFunc(comments, func(a, b Located) int { return a.Line - b.Line })
		for i := 0; i < len(comments); {
			j := i
			strong, weak := 0, 0
			for j < len(comments) && (j == i || comments[j].Line == comments[j-1].Line+1) {
				s, w := codeLike(comments[j].Text)
				if s {
					strong++
				}
				if w || s {
					weak++
				}
				j++
			}
			if strong > 0 || weak >= 2 {
				out = append(out, Finding{
					Job: "static", Rule: "commented-out-code", Severity: Consider,
					File: file, Line: comments[i].Line,
					Message: fmt.Sprintf("the change adds code as a comment, %d line(s) from %s:%d; the version control has the old code, and a reader cannot tell a comment that was code from one that is meant", j-i, file, comments[i].Line),
					Fix:     "delete it; git remembers it",
				})
			}
			i = j
		}
	}
	return out
}

var (
	goDroppedError = regexp.MustCompile(`^\s*_\s*=\s*err\b`)
	emptyCatch     = regexp.MustCompile(`\bcatch\s*(\([^)]*\))?\s*\{\s*\}`)
	openCatch      = regexp.MustCompile(`\bcatch\s*(\([^)]*\))?\s*\{\s*$`)
	promiseCatch   = regexp.MustCompile(`\.catch\(\s*(\(\s*\w*\s*\)|\w+)?\s*=>\s*\{\s*\}\s*\)`)
	exceptPass     = regexp.MustCompile(`^\s*except\b[^:]*:\s*pass\s*$`)
	exceptOpen     = regexp.MustCompile(`^\s*except\b[^:]*:\s*$`)
	closingBrace   = regexp.MustCompile(`^\s*\}`)
	passLine       = regexp.MustCompile(`^\s*pass\s*$`)
)

// checkSwallowedErrors reports an error the change catches and drops: a Go
// error assigned to the blank identifier, an empty catch in JavaScript or
// TypeScript, an except that passes in Python.
func checkSwallowedErrors(c *Change) []Finding {
	added, _ := diffSides(c.Diff)
	var out []Finding
	for _, file := range slices.Sorted(maps.Keys(added)) {
		if !isCodeFile(file) {
			continue
		}
		lines := added[file]
		for i, l := range lines {
			next := ""
			if i+1 < len(lines) && lines[i+1].Line == l.Line+1 {
				next = lines[i+1].Text
			}
			hit := false
			switch {
			case strings.HasSuffix(file, ".go"):
				hit = goDroppedError.MatchString(l.Text)
			case grammarOf(file) != "":
				hit = emptyCatch.MatchString(l.Text) || promiseCatch.MatchString(l.Text) ||
					(openCatch.MatchString(l.Text) && closingBrace.MatchString(next))
			case strings.HasSuffix(file, ".py"):
				hit = exceptPass.MatchString(l.Text) || (exceptOpen.MatchString(l.Text) && passLine.MatchString(next))
			}
			if !hit {
				continue
			}
			out = append(out, Finding{
				Job: "static", Rule: "error-swallowed", Severity: Consider,
				File: file, Line: l.Line,
				Message: fmt.Sprintf("the change catches an error and drops it: %s; a dropped error is a failure the program has decided not to know about", strings.TrimSpace(l.Text)),
				Fix:     "handle it, return it, or write beside it why it cannot matter",
			})
		}
	}
	return out
}
