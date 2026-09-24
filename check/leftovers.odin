package check

// What a change leaves behind by accident has a shape: a debugger
// statement, a task marker nobody is named on, code kept as a comment, an
// error caught and dropped. Each is a pattern over the lines the change
// adds.

import "core:fmt"
import "core:slice"
import "core:strings"

import "../change"
import "../finding"

// Debug_Marker is a call or statement that exists to be removed before a
// change is done, by language. Ordinary printing is not here: a command's
// output and a debug print share a function.
Debug_Marker :: struct {
	suffixes: []string,
	// shell marks a pattern that belongs to any shell script, whose name
	// usually does not say that it is one.
	shell:    bool,
	pattern:  string,
	severity: finding.Severity,
}

@(private = "file")
debug_markers := []Debug_Marker {
	{{".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"}, false, `^\s*debugger\s*;?\s*$`, .Consider},
	{{".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx"}, false, `\bconsole\.(log|debug|trace)\(`, .Note},
	{{".py"}, false, `\b(breakpoint\(\)|pdb\.set_trace\(\)|ipdb\.set_trace\(\))`, .Consider},
	{{".rs"}, false, `\bdbg!\(`, .Consider},
	{nil, true, `^\s*set\s+-[a-z]*x[a-z]*\b`, .Consider},
	{nil, true, `^\s*set\s+-o\s+xtrace\b`, .Consider},
	{nil, true, `^\s*PS4=`, .Consider},
	{{".go"}, false, `\b(spew\.Dump|litter\.Dump|pp\.Print)\(`, .Consider},
	{{".rb"}, false, `\b(binding\.pry|byebug|debugger)\b`, .Consider},
	{nil, false, `\b(Printf|Println|Print|log|print|debug)\(\s*["'](DEBUG|XXX|HERE|>>>)`, .Consider},
}

// check_debug_leftovers reports the debugging a change adds and did not
// remove.
check_debug_leftovers :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for file in sorted_keys(s.c.added) {
		if !change.is_code_file(file) {
			continue
		}
		lines := s.c.added[file]
		for l in lines {
			for m in debug_markers {
				if m.suffixes != nil && !has_suffix(file, m.suffixes) {
					continue
				}
				if m.shell && change.shell_for(s.c, file) == "" {
					continue
				}
				if !matches(m.pattern, l.text) {
					continue
				}
				append(
					out,
					static(
						"debug-leftover",
						m.severity,
						fmt.aprintf(
							"the change adds debugging output: %s",
							strings.trim_space(l.text),
						),
						"remove it before the change is done",
						file = file,
						line = l.line,
					),
				)
				break
			}
		}
	}
}

// task_marker is a comment that names work left undone; task_reference
// what makes it answerable: an issue number, a ticket key, a link, or a
// name in parentheses.
task_marker    :: `\b(TODO|FIXME|XXX|HACK)\b`
task_reference :: `\#\d+|\b[A-Z][A-Z0-9]+-\d+\b|https?://|\(\w+\)`

// check_todos reports a task marker the change adds with nothing to find
// it by again. Unreferenced, it is a promise the log will not keep.
check_todos :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for comment in s.c.comments {
		if !matches(task_marker, comment.text) || matches(task_reference, comment.text) {
			continue
		}
		append(
			out,
			static(
				"todo-without-reference",
				.Note,
				fmt.aprintf(
					"the change adds a task marker nothing refers to: %q",
					first_line(comment.text, context.temp_allocator),
				),
				"name the issue or the person, or do the work now",
				file = comment.file,
				line = comment.line,
			),
		)
	}
}

// strong_code is a comment line that is code beyond doubt: an assignment
// operator, a call closed and terminated, a closing brace terminated, an
// arrow function. weak_code is a line shaped like a statement, which two
// in a row make into commented-out code.
strong_code :: `:=|\);\s*$|\};\s*$|=>|^\s*\}\s*else\s*\{`
weak_code   :: `^(if|for|while|return|func|fn|def|import|const|let|var|switch|case|else|try|catch|package|use|pub|proc|struct|type|class|await|export)\b.*[({=:;]\s*$|^[\w.]+\(.*\)\s*;?\s*$|[;{}]\s*$`

// code_like is whether a comment line reads as code, and how surely.
code_like :: proc(text: string) -> (strong, weak: bool) {
	trimmed := strings.trim_space(text)
	if trimmed == "" || directive(trimmed) {
		return false, false
	}
	return matches(strong_code, trimmed), matches(weak_code, trimmed)
}

// check_commented_code reports code the change keeps as comments. A run
// of consecutive comment lines is one candidate; it is reported when two
// of its lines are shaped like statements, or one is code beyond doubt.
check_commented_code :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	by_file := make(map[string][dynamic]change.Located, context.temp_allocator)
	for comment in s.c.comments {
		list := by_file[comment.file]
		if list.allocator.procedure == nil {
			list = make([dynamic]change.Located, context.temp_allocator)
		}
		append(&list, comment)
		by_file[comment.file] = list
	}
	for file in sorted_keys(by_file) {
		comments := by_file[file][:]
		slice.sort_by_cmp(comments, proc(a, b: change.Located) -> slice.Ordering {
			return .Less if a.line < b.line else (.Greater if a.line > b.line else .Equal)
		})
		i := 0
		for i < len(comments) {
			j := i
			strong, weak := 0, 0
			for j < len(comments) && (j == i || comments[j].line == comments[j - 1].line + 1) {
				st, wk := code_like(comments[j].text)
				if st {
					strong += 1
				}
				if wk || st {
					weak += 1
				}
				j += 1
			}
			if strong > 0 || weak >= 2 {
				append(
					out,
					static(
						"commented-out-code",
						.Consider,
						fmt.aprintf(
							"the change adds code as a comment, %d line(s) from %s:%d; the version control has the old code, and a reader cannot tell a comment that was code from one that is meant",
							j - i,
							file,
							comments[i].line,
						),
						"delete it; git remembers it",
						file = file,
						line = comments[i].line,
					),
				)
			}
			i = j
		}
	}
}

go_dropped_error :: `^\s*_\s*=\s*err\b`
empty_catch      :: `\bcatch\s*(\([^)]*\))?\s*\{\s*\}`
open_catch       :: `\bcatch\s*(\([^)]*\))?\s*\{\s*$`
promise_catch    :: `\.catch\(\s*(\(\s*\w*\s*\)|\w+)?\s*=>\s*\{\s*\}\s*\)`
except_pass      :: `^\s*except\b[^:]*:\s*pass\s*$`
except_open      :: `^\s*except\b[^:]*:\s*$`
closing_brace    :: `^\s*\}`
pass_line        :: `^\s*pass\s*$`

// check_swallowed_errors reports an error the change catches and drops:
// a Go error assigned to the blank identifier, an empty catch in
// JavaScript or TypeScript, an except that passes in Python.
check_swallowed_errors :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for file in sorted_keys(s.c.added) {
		if !change.is_code_file(file) {
			continue
		}
		lines := s.c.added[file]
		for l, i in lines {
			next := ""
			if i + 1 < len(lines) && lines[i + 1].line == l.line + 1 {
				next = lines[i + 1].text
			}
			hit := false
			switch {
			case strings.has_suffix(file, ".go"):
				hit = matches(go_dropped_error, l.text)
			case grammar_of(file) != "":
				hit =
					matches(empty_catch, l.text) ||
					matches(promise_catch, l.text) ||
					(matches(open_catch, l.text) && matches(closing_brace, next))
			case strings.has_suffix(file, ".py"):
				hit =
					matches(except_pass, l.text) ||
					(matches(except_open, l.text) && matches(pass_line, next))
			}
			if !hit {
				continue
			}
			append(
				out,
				static(
					"error-swallowed",
					.Consider,
					fmt.aprintf(
						"the change catches an error and drops it: %s; a dropped error is a failure the program has decided not to know about",
						strings.trim_space(l.text),
					),
					"handle it, return it, or write beside it why it cannot matter",
					file = file,
					line = l.line,
				),
			)
		}
	}
}
