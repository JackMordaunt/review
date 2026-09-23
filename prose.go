package main

// A comment whose words are the code's own words says nothing the code
// does not. It is never a claim, so the claims job should not be paying to
// read it, and it is worth a word of its own: the habit of narrating each
// line is the habit this catches.

import (
	"fmt"
	"strings"
)

// minRestatedWords is the fewest content words a comment needs before it
// can be said to restate anything: one word is a label, not a sentence.
const minRestatedWords = 2

// restates is whether a comment's content words all appear in the code it
// sits above. A directive, a dismissal, a task marker and a link are not
// prose about the code and are never said to restate it.
func restates(comment Located) bool {
	text := comment.Text
	if comment.Below == "" || directive(text) {
		return false
	}
	words := contentWords(text)
	if len(words) < minRestatedWords {
		return false
	}
	code := contentWords(strings.SplitN(comment.Below, "\n", 2)[0])
	for w := range words {
		if !code[w] {
			return false
		}
	}
	return true
}

// directive is whether a comment is one the tools read rather than a
// person: a compiler or linter instruction, a dismissal, a task marker, a
// link.
func directive(text string) bool {
	trimmed := strings.TrimSpace(text)
	for _, prefix := range []string{"go:", "nolint", "eslint", "@ts-", "prettier", "review:ignore", "#!", "+build", "lint:"} {
		if strings.HasPrefix(trimmed, prefix) {
			return true
		}
	}
	for _, marker := range []string{"TODO", "FIXME", "XXX", "HACK", "http://", "https://"} {
		if strings.Contains(trimmed, marker) {
			return true
		}
	}
	return false
}

// checkRestating reports the comments the change adds whose every word the
// code below already says.
func checkRestating(c *Change) []Finding {
	var out []Finding
	for _, comment := range c.Comments {
		if !restates(comment) {
			continue
		}
		out = append(out, Finding{
			Job: "static", Rule: "comment-restates-code", Severity: Note,
			File: comment.File, Line: comment.Line,
			Message: fmt.Sprintf("the comment %q says only what the line below it says; a comment that narrates the code is read twice and informs once", firstLine(comment.Text)),
			Fix:     "say why, or say nothing",
		})
	}
	return out
}
