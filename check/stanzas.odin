package check

// A body reads in stanzas separated by a blank line. Acquiring a resource
// and deferring its release is a stanza of its own: glued to the loop or
// call that uses it, the teardown reads as part of the work. Where the
// teardown is a defer, the end of that stanza is a line pattern, and the
// pattern is the check. Where a stanza ends otherwise is judged by the
// stanzas job.

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../finding"

// check_stanza_glued_teardown reports an added defer whose run of
// acquisitions and defers is followed, without a blank line, by code at
// the same depth.
check_stanza_glued_teardown :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	//review:ignore odin-allocator-parameter a Check's signature is fixed; the work is delegated to a helper that takes the allocator
	report_glued_teardowns(s, out, context.temp_allocator)
}

// report_glued_teardowns is the check with its scratch allocator exposed;
// the lines of each file are read into one buffer the files share.
@(private = "file")
report_glued_teardowns :: proc(s: Scope, out: ^[dynamic]finding.Finding, allocator: runtime.Allocator) {
	lines_of := make([dynamic]string, allocator)
	for file in sorted_keys(s.c.added) {
		if !has_suffix(file, {".odin", ".go", ".zig"}) {
			continue
		}
		src, ok := s.sources[file]
		if !ok {
			continue
		}

		clear(&lines_of)
		rest := string(src)
		for line in strings.split_lines_iterator(&rest) {
			append(&lines_of, line)
		}
		lines := lines_of[:]

		covered := 0
		for l in s.c.added[file] {
			if l.line <= covered || l.line > len(lines) || !is_defer(lines[l.line - 1]) {
				continue
			}
			glued, end := teardown_glued(lines, l.line - 1)
			covered = end + 1
			if !glued {
				continue
			}
			append(
				out,
				static(
					"stanza-glued-teardown",
					.Consider,
					fmt.aprintf(
						"the teardown `%s` runs straight into `%s`; setup and teardown are a stanza of their own",
						strings.trim_space(lines[l.line - 1]),
						strings.trim_space(lines[end + 1]),
					),
					"put a blank line after the stanza's last defer",
					file = file,
					line = l.line,
				),
			)
		}
	}
}

// teardown_glued walks the stanza from the defer at index at: further
// defers, and acquisitions that a defer follows, belong to it. It reports
// whether the line after the stanza is code at the same depth, and the
// index of the stanza's last line.
@(private = "file")
teardown_glued :: proc(lines: []string, at: int) -> (glued: bool, end: int) {
	indent := leading_space(lines[at])
	end = statement_end(lines, at)
	for end + 1 < len(lines) {
		next := lines[end + 1]
		text := strings.trim_space(next)
		if text == "" || len(leading_space(next)) < len(indent) || strings.has_prefix(text, "}") {
			return false, end
		}
		if is_defer(next) {
			end = statement_end(lines, end + 1)
			continue
		}
		after := end + 2
		if after < len(lines) && leading_space(lines[after]) == indent && is_defer(lines[after]) {
			end = statement_end(lines, after)
			continue
		}
		return true, end
	}
	return false, end
}

// statement_end is the index of the line that closes the statement at
// index at: itself, or for a block or call left open, the next line at the
// same depth that closes it.
@(private = "file")
statement_end :: proc(lines: []string, at: int) -> int {
	text := strings.trim_right_space(lines[at])
	if !strings.has_suffix(text, "{") && !strings.has_suffix(text, "(") {
		return at
	}
	indent := leading_space(lines[at])
	for i in at + 1 ..< len(lines) {
		closing := strings.trim_space(lines[i])
		if leading_space(lines[i]) == indent && (strings.has_prefix(closing, "}") || strings.has_prefix(closing, ")")) {
			return i
		}
	}
	return at
}

@(private = "file")
is_defer :: proc(line: string) -> bool {
	text := strings.trim_space(line)
	for word in ([]string{"defer", "errdefer"}) {
		if strings.has_prefix(text, word) && len(text) > len(word) && (text[len(word)] == ' ' || text[len(word)] == '{') {
			return true
		}
	}
	return false
}

@(private = "file")
leading_space :: proc(line: string) -> string {
	return line[:len(line) - len(strings.trim_left_space(line))]
}
