package check

// The anti-gaming checks hold the review to itself: a change that
// dismisses what the reading would find, or deletes the tests that would
// have failed, is measured rather than waved through.

import "core:fmt"
import "core:strings"

import "../change"
import "../finding"
import "../frontend"
import "../txt"

// rule_id is what a dismissal's rule id has to look like. The prose that
// documents the mechanism writes placeholders (<rule>) and quoted
// examples, which match the ignore pattern but dismiss nothing.
rule_id :: `^[a-z][a-z0-9-]*$`

// check_suppression_added reports a change that adds its own dismissal,
// before the readers have run. The finding names no file, so it cannot
// be dismissed in turn.
check_suppression_added :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	spots := make([dynamic]string, context.temp_allocator)
	for file in sorted_keys(s.c.added) {
		if !change.is_code_file(file) {
			continue
		}
		lines := s.c.added[file]
		for l in lines {
			rule, _, found := finding.dismissal(l.text)
			if !found || !matches(rule_id, rule) {
				continue
			}
			append(&spots, fmt.tprintf("%s:%d (%s)", file, l.line, rule))
		}
	}
	if len(spots) == 0 {
		return
	}
	append(
		out,
		static(
			"suppression-added",
			.Must_Fix,
			fmt.aprintf(
				"the change adds its own dismissal%s: %s; a dismissal is a decision for the person reviewing the change, and a review that dismisses itself cannot be failed",
				plural(len(spots)),
				strings.join(spots[:], "; ", context.temp_allocator),
			),
			"correct what the dismissal covers; a dismissal belongs to the person reviewing, who accepts it deliberately",
		),
	)
}

// dismissals counts the dismissals in the tree per rule, with where each
// is and why, so that the rules people argue with are visible: a rule
// dismissed everywhere is a rule to rewrite.
dismissals :: proc(s: Scope, allocator := context.allocator) -> string {
	Spot :: struct {
		where_at, why: string,
	}
	by_rule := make(map[string][dynamic]Spot, context.temp_allocator)
	for file in sorted_keys(s.sources) {
		if !change.is_code_file(file) {
			continue
		}
		rest := string(s.sources[file])
		number := 0
		for line in strings.split_lines_iterator(&rest) {
			number += 1
			rule, why, found := finding.dismissal(line)
			if !found || !matches(rule_id, rule) {
				continue
			}
			// A dismissal quoted inside a string literal, as a test's
			// fixture is, ends where the literal's line does.
			if cut := strings.index(why, "\\n"); cut >= 0 {
				why = why[:cut]
			}
			why = strings.trim_space(strings.trim_suffix(strings.trim_space(why), "\""))
			if why == "" {
				why = "no reason given"
			}
			spots := by_rule[rule]
			if spots.allocator.procedure == nil {
				spots = make([dynamic]Spot, context.temp_allocator)
			}
			append(&spots, Spot{fmt.tprintf("%s:%d", file, number), why})
			by_rule[strings.clone(rule, context.temp_allocator)] = spots
		}
	}
	b := strings.builder_make(allocator)
	if len(by_rule) == 0 {
		strings.write_string(&b, "no dismissals in the tree\n")
		return strings.to_string(b)
	}
	rules := sorted_keys(by_rule)
	// The most dismissed first, the rest by name.
	for i in 1 ..< len(rules) {
		for j := i; j > 0 && len(by_rule[rules[j]]) > len(by_rule[rules[j - 1]]); j -= 1 {
			rules[j], rules[j - 1] = rules[j - 1], rules[j]
		}
	}
	for rule in rules {
		spots := by_rule[rule]
		fmt.sbprintf(&b, "%-28s %d\n", rule, len(spots))
		for spot in spots {
			fmt.sbprintf(&b, "    %s  %s\n", spot.where_at, spot.why)
		}
	}
	return strings.to_string(b)
}

// The shapes a test's declaration takes on a diff line, per runner.
go_test           :: `^func ((?:Test|Benchmark|Fuzz)[A-Za-z0-9_]+)\(`
py_test           :: `^(?:async\s+)?def (test_\w+)\(`
js_test_call      :: `^(?:Deno\.test|test|describe|it)(?:\.(?:skip|only|todo|fails|failing|ignore|concurrent|serial))*\(`
rs_test_attribute :: `^\#\[[\w:]*test(\(|\])`
rs_fn             :: `^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn (\w+)\(`
java_annotation   :: `^@[\w.]+(?:\([^()]*\))?\s*`
java_method       :: `^(?:(?:public|protected|private|static|final|abstract|synchronized|default)\s+)*(?:<[^>]*>\s*)?[\w.<>\[\]?,]+\s+(\w+)\s*\(`

// check_deleted_tests reports the tests a change deletes. A test is never
// heard from again once deleted, so deletion is where a test the reading
// would have failed goes to pass the review. A test the change also adds
// under a name made of the same words is a rename, and is spared.
check_deleted_tests :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	spoken := added_test_names(s.c.added, context.temp_allocator)
	for file in sorted_keys(s.c.removed) {
		if !is_test_file(file) &&
		   !strings.has_suffix(file, ".rs") &&
		   !strings.has_suffix(file, ".java") {
			continue
		}
		removed := s.c.removed[file]
		names := make([dynamic]string, context.temp_allocator)
		seen := make(map[string]bool, context.temp_allocator)
		for text, i in removed {
			name := removed_test_name(text)
			if strings.has_suffix(file, ".rs") {
				// A Rust test is the function after the attribute, and
				// only that; a deleted function without one is not a test.
				name = ""
				if matches(rs_test_attribute, strings.trim_space(text)) && i + 1 < len(removed) {
					if m, ok := capture(rs_fn, strings.trim_space(removed[i + 1])); ok {
						name = m[1]
					}
				}
			}
			if strings.has_suffix(file, ".java") {
				// A Java test is the method a test annotation marks, and
				// only that; a deleted helper beside it is not a test.
				name = removed_java_test_name(removed[:], i)
			}
			if name == "" || seen[name] {
				continue
			}
			seen[name] = true
			if !covered(name, spoken) {
				append(&names, name)
			}
		}
		if len(names) == 0 {
			continue
		}
		shown := make([dynamic]string, context.temp_allocator)
		for name, i in names {
			if i == 8 {
				append(&shown, fmt.tprintf("and %d more", len(names) - 8))
				break
			}
			append(&shown, fmt.tprintf("%q", name))
		}
		append(
			out,
			static(
				"test-deleted",
				.Must_Fix,
				fmt.aprintf(
					"the change deletes the test%s %s from %s; a deleted test cannot fail again, so deletion is where a failing test goes to pass the review",
					plural(len(names)),
					strings.join(shown[:], ", ", context.temp_allocator),
					file,
				),
				fmt.aprintf(
					"restore the test, or dismiss it where a reader can read why: a review:ignore comment naming test-deleted, with the reason, in %s",
					file,
				),
				file = file,
				symbol = strings.clone(names[0]),
			),
		)
	}
}

// removed_test_name reads the name of a deleted test out of its removed
// line, in the shapes the tool's languages write tests in.
removed_test_name :: proc(text: string) -> string {
	trimmed := strings.trim_left(text, " \t")
	if m, ok := capture(go_test, trimmed); ok {
		return m[1]
	}
	if m, ok := capture(py_test, trimmed); ok {
		return m[1]
	}
	if end, ok := capture_end(js_test_call, trimmed); ok {
		return read_quoted(strings.trim_left(trimmed[end:], " \t"))
	}
	return ""
}

// removed_java_test_name reads the name of the method a test annotation on
// removed line i marks: on the annotation's own line, or on the first
// line after it that is not another annotation.
removed_java_test_name :: proc(removed: []string, i: int) -> string {
	first := strings.trim_space(removed[i])
	if _, ok := capture_end(frontend.java_test_annotation, first); !ok {
		return ""
	}
	for j in i ..< min(i + 8, len(removed)) {
		line := strings.trim_space(removed[j])
		for {
			end, ok := capture_end(java_annotation, line)
			if !ok || end == 0 {
				break
			}
			line = line[end:]
		}
		if line == "" {
			continue
		}
		if m, ok := capture(java_method, line); ok {
			return m[1]
		}
		return ""
	}
	return ""
}

// read_quoted reads the string literal a JS test registration is named
// by, from the text that follows its opening parenthesis.
read_quoted :: proc(text: string) -> string {
	if len(text) == 0 {
		return ""
	}
	q := text[0]
	if q != '"' && q != '\'' && q != '`' {
		return ""
	}
	if end := strings.index_byte(text[1:], q); end >= 0 {
		return text[1:1 + end]
	}
	return ""
}

// added_test_names collects the names of the tests a change adds, read
// with the same shapes the removed side is read with, so that a rename is
// not read as a deletion.
added_test_names :: proc(
	added: map[string][dynamic]change.Diff_Line,
	allocator := context.allocator,
) -> []string {
	seen := make(map[string]bool, context.temp_allocator)
	for _, lines in added {
		for l in lines {
			if name := added_test_name(strings.trim_left(l.text, " \t")); name != "" {
				seen[name] = true
			}
		}
	}
	return sorted_keys(seen, allocator)
}

// added_test_name reads a test's name off an added line, in any runner's
// shape, or nothing.
added_test_name :: proc(trimmed: string) -> string {
	for pattern in ([]string{go_test, py_test, rs_fn, java_method}) {
		if m, ok := capture(pattern, trimmed); ok {
			return m[1]
		}
	}
	if end, ok := capture_end(js_test_call, trimmed); ok {
		return read_quoted(strings.trim_left(trimmed[end:], " \t"))
	}
	return ""
}

// covered reports whether a deleted test's name is spoken for by a test
// the change adds: every word of the old name is in a new one, which is
// what a rename or a re-anchored test looks like.
covered :: proc(deleted: string, spoken: []string) -> bool {
	want := test_words(deleted, context.temp_allocator)
	if len(want) == 0 {
		return false
	}
	for name in spoken {
		have := test_words(name, context.temp_allocator)
		says_all := true
		for w in want {
			found := false
			for h in have {
				if h == w {
					found = true
					break
				}
			}
			if !found {
				says_all = false
				break
			}
		}
		if says_all {
			return true
		}
	}
	return false
}

// test_words breaks a test's name into its lowercased words: camel humps
// and underscores for the Go shapes, spaces for the strings the
// JavaScript shapes are named by, with the runner's own prefixes and
// short leftovers left out.
test_words :: proc(name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for part in txt.split_words(name, context.temp_allocator) {
		for piece in strings.fields(part, context.temp_allocator) {
			word := strings.to_lower(piece, allocator)
			if len(word) < 3 {
				continue
			}
			switch word {
			case "test", "benchmark", "fuzz", "skip", "only", "todo", "fails":
				continue
			}
			append(&out, word)
		}
	}
	return out[:]
}
