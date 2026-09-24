/*
Package check is the deterministic readings: what a change can be measured
for without a model, from the commit message to the code it adds — its
names, tests, bodies, comments and leftovers — and the repository around
it. A check that passes says nothing. Each is independent of the others,
and every finding cites a rule the catalogue describes.
*/
package check

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:text/regex"
import "core:unicode"

import "../change"
import "../finding"
import "../tree"

// Scope is what a check reads: the change, and the repository at its end.
Scope :: struct {
	c:       ^change.Change,
	t:       tree.Tree,
	files:   []string,
	sources: map[string][]byte,
}

// Check measures a change and appends what it noticed.
Check :: #type proc(s: Scope, out: ^[dynamic]finding.Finding)

// checks are the deterministic readings in the order the catalogue lists
// them: the message, the history, the review's own mechanisms, and then
// the code the change adds.
checks :: proc() -> []Check {
	@(static) all := []Check {
		check_entropy,
		check_compressibility,
		check_common,
		check_venting,
		check_mood,
		check_body,
		check_formatting,
		check_names_unknown,
		check_temporal,
		check_suppression_added,
		check_deleted_tests,
		check_names,
		check_test_assertions,
		check_tautologies,
		check_clones,
		check_shape,
		check_restating,
		check_todos,
		check_commented_code,
		check_debug_leftovers,
		check_swallowed_errors,
		check_unreferenced,
		check_code_without_tests,
	}
	return all
}

// scope_of reads the repository once for every check that needs it.
scope_of :: proc(c: ^change.Change, t: tree.Tree, allocator := context.allocator) -> Scope {
	s := Scope {
		c = c,
		t = t,
	}
	s.files, _ = tree.files(t, allocator)
	s.sources, _ = tree.sources(t, allocator)
	return s
}

// run applies every check. Everything a finding holds is allocated from
// allocator.
run :: proc(s: Scope, allocator := context.allocator) -> []finding.Finding {
	context.allocator = allocator
	sides(s)
	out := make([dynamic]finding.Finding)
	for check in checks() {
		check(s, &out)
	}
	return out[:]
}

// collect is one check's findings, for a test of it alone.
collect :: proc(s: Scope, check: Check, allocator := context.allocator) -> []finding.Finding {
	context.allocator = allocator
	sides(s)
	out := make([dynamic]finding.Finding)
	check(s, &out)
	return out[:]
}

// sides splits the diff a change was handed without going through gather,
// so that a check reading the added lines reads them.
sides :: proc(s: Scope) {
	if len(s.c.added) == 0 && len(s.c.removed) == 0 && s.c.diff != "" {
		s.c.added, s.c.removed = change.diff_sides(s.c.diff)
	}
}

// static is a finding a deterministic check made, which verifies itself:
// what it reports was measured, not read once.
static :: proc(
	rule: string,
	severity: finding.Severity,
	message, fix: string,
	file := "",
	line := 0,
	symbol := "",
) -> finding.Finding {
	return finding.Finding {
		job = "static",
		rule = rule,
		severity = severity,
		message = message,
		fix = fix,
		file = file,
		line = line,
		symbol = symbol,
		verified = true,
	}
}

// plural is the s a count takes when it is not one.
plural :: proc(n: int) -> string {
	return "" if n == 1 else "s"
}

// first_line is the first line of a text, cut short past 140 characters.
first_line :: proc(s: string, allocator := context.allocator) -> string {
	line := s
	if i := strings.index_byte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	if len(line) > 140 {
		return strings.concatenate({line[:140], "…"}, allocator)
	}
	return line
}

// quoted joins names for a message, each in quotes.
quoted :: proc(names: []string, allocator := context.allocator) -> string {
	out := make([]string, len(names), context.temp_allocator)
	for n, i in names {
		out[i] = fmt.tprintf("%q", n)
	}
	return strings.join(out, ", ", allocator)
}

// sorted_keys is a map's keys in order, so that a check reports in an
// order a reader can follow.
sorted_keys :: proc(m: map[$K]$V, allocator := context.temp_allocator) -> []K {
	keys, _ := slice.map_keys(m, allocator)
	slice.sort(keys)
	return keys
}

// set reads a space-separated list of words into a set, allocated to live
// for the program: the lists are the checks' vocabulary.
set :: proc(words: string) -> map[string]bool {
	out := make(map[string]bool, runtime.heap_allocator())
	for w in strings.fields(words, context.temp_allocator) {
		out[strings.clone(w, runtime.heap_allocator())] = true
	}
	return out
}

// fields splits on anything that is not a letter or a digit.
fields :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	start := -1
	for r, i in s {
		if unicode.is_letter(r) || unicode.is_digit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			append(&out, s[start:i])
			start = -1
		}
	}
	if start >= 0 {
		append(&out, s[start:])
	}
	return out[:]
}

// has_suffix reports whether a path ends in any of the suffixes.
has_suffix :: proc(path: string, suffixes: []string) -> bool {
	for s in suffixes {
		if strings.has_suffix(path, s) {
			return true
		}
	}
	return false
}

// is_test_file reports whether a path is one a test runner reads, in any
// of the naming habits the tool's languages have: a marker in the name,
// or a tests directory. A Rust unit test sits in the source file beside
// the code, and that file is not a test file.
is_test_file :: proc(path: string) -> bool {
	base := path
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		base = path[i + 1:]
	}
	for marker in ([]string{"_test.", ".test.", ".spec."}) {
		if strings.contains(base, marker) {
			return true
		}
	}
	if strings.has_suffix(base, ".py") &&
	   (strings.has_prefix(base, "test_") || strings.has_suffix(base, "_test.py")) {
		return true
	}
	dir := path[:max(0, len(path) - len(base))]
	for part in strings.split(dir, "/", context.temp_allocator) {
		if part == "tests" || part == "__tests__" || part == "test" {
			return true
		}
	}
	return false
}

// grammar_of is the ast-grep grammar a TypeScript or JavaScript file is
// read with, or nothing for any other language.
grammar_of :: proc(path: string) -> string {
	switch {
	case strings.has_suffix(path, ".ts"):
		return "ts"
	case strings.has_suffix(path, ".tsx"):
		return "tsx"
	case has_suffix(path, {".js", ".jsx", ".mjs", ".cjs"}):
		return "js"
	}
	return ""
}

// The patterns the checks match are compiled once and kept for the
// program; a check runs over every line of a change, and a pattern is not
// worth compiling per line. The cache is shared between threads, as the
// test runner's are, so it is locked.
@(private)
patterns: map[string]regex.Regular_Expression
@(private)
patterns_lock: sync.Mutex

@(init)
init_patterns :: proc "contextless" () {
	context = runtime.default_context()
	patterns = make(map[string]regex.Regular_Expression, runtime.heap_allocator())
}

// rx is the compiled form of a pattern, in Go's syntax as far as the two
// engines share it.
rx :: proc(pattern: string) -> regex.Regular_Expression {
	sync.mutex_lock(&patterns_lock)
	defer sync.mutex_unlock(&patterns_lock)
	if re, ok := patterns[pattern]; ok {
		return re
	}
	re, err := regex.create(pattern, {}, runtime.heap_allocator())
	if err != nil {
		panic(fmt.tprintf("check: pattern %q: %v", pattern, err))
	}
	patterns[strings.clone(pattern, runtime.heap_allocator())] = re
	return re
}

// matches reports whether a pattern matches anywhere in the text.
matches :: proc(pattern, text: string) -> bool {
	_, ok := regex.match(rx(pattern), text, context.temp_allocator)
	return ok
}

// capture is the groups of the first match: the whole match first, then
// each group, empty where a group did not take part.
capture :: proc(
	pattern, text: string,
	allocator := context.temp_allocator,
) -> (
	groups: []string,
	ok: bool,
) {
	cap: regex.Capture
	cap, ok = regex.match(rx(pattern), text, allocator)
	if !ok {
		return nil, false
	}
	return cap.groups, true
}

// capture_end is where the first match ends, for a reader that continues
// from there.
capture_end :: proc(pattern, text: string) -> (end: int, ok: bool) {
	cap: regex.Capture
	cap, ok = regex.match(rx(pattern), text, context.temp_allocator)
	if !ok {
		return 0, false
	}
	return cap.pos[0][1], true
}

// find_all is every match of a pattern in the text, whole.
find_all :: proc(pattern, text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	it, err := regex.create_iterator(text, pattern, {}, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	defer regex.destroy_iterator(it, context.temp_allocator)
	for {
		cap, _, ok := regex.match_iterator(&it)
		if !ok {
			break
		}
		append(&out, cap.groups[0])
	}
	return out[:]
}

// remove_all is the text with every match of a pattern replaced by a
// space.
remove_all :: proc(pattern, text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	it, err := regex.create_iterator(text, pattern, {}, context.temp_allocator)
	if err != nil {
		return strings.clone(text, allocator)
	}
	defer regex.destroy_iterator(it, context.temp_allocator)
	last := 0
	for {
		cap, _, ok := regex.match_iterator(&it)
		if !ok {
			break
		}
		strings.write_string(&b, text[last:cap.pos[0][0]])
		strings.write_string(&b, " ")
		last = cap.pos[0][1]
	}
	strings.write_string(&b, text[last:])
	return strings.to_string(b)
}
