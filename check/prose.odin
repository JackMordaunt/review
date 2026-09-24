package check

// A comment whose words are the code's own words says nothing the code
// does not. It is never a claim, so the claims job should not be paying to
// read it, and the habit of narrating each line is the habit this
// catches.

import "core:fmt"
import "core:strings"

import "../change"
import "../finding"

// min_restated_words is the fewest content words a comment needs before
// it can be said to restate anything: one word is a label.
min_restated_words :: 2

// restates is whether a comment's content words all appear in the code
// it sits above. A directive, a dismissal, a task marker and a link are
// not prose about the code and are never said to restate it.
restates :: proc(comment: change.Located) -> bool {
	if comment.below == "" || directive(comment.text) {
		return false
	}
	words := content_words(comment.text, context.temp_allocator)
	if len(words) < min_restated_words {
		return false
	}
	code := content_words(subject_of(comment.below), context.temp_allocator)
	for w in words {
		if !code[w] {
			return false
		}
	}
	return true
}

// directive is whether a comment is one the tools read rather than a
// person: a compiler or linter instruction, a dismissal, a task marker, a
// link.
directive :: proc(text: string) -> bool {
	trimmed := strings.trim_space(text)
	for prefix in ([]string{"go:", "nolint", "eslint", "@ts-", "prettier", "review:ignore", "#!", "+build", "lint:"}) {
		if strings.has_prefix(trimmed, prefix) {
			return true
		}
	}
	for marker in ([]string{"TODO", "FIXME", "XXX", "HACK", "http://", "https://"}) {
		if strings.contains(trimmed, marker) {
			return true
		}
	}
	return false
}

// check_restating reports the comments the change adds whose every word
// the code below already says.
check_restating :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for comment in s.c.comments {
		if !restates(comment) {
			continue
		}
		append(
			out,
			static(
				"comment-restates-code",
				.Note,
				fmt.aprintf(
					"the comment %q says only what the line below it says; a comment that narrates the code is read twice and informs once",
					first_line(comment.text, context.temp_allocator),
				),
				"say why, or say nothing",
				file = comment.file,
				line = comment.line,
			),
		)
	}
}
