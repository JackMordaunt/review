package finding

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
severity_round_trips :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_severity(" Must-Fix "), Severity.Must_Fix)
	testing.expect_value(t, parse_severity("error"), Severity.Must_Fix)
	testing.expect_value(t, parse_severity("warning"), Severity.Consider)
	testing.expect_value(t, parse_severity("whatever"), Severity.Note)
	testing.expect_value(t, severity_name(.Consider), "consider")
}

@(test)
to_string_says_where_and_what :: proc(t: ^testing.T) {
	s := to_string(
		Finding {
			job = "tests",
			rule = "cannot-fail",
			severity = .Must_Fix,
			file = "a_test.go",
			line = 4,
			message = "m",
			fix = "do x",
		},
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		s,
		"must-fix: a_test.go:4: m\n      → do x\n      [tests/cannot-fail]",
	)
	s = to_string(
		Finding {
			job = "namer",
			rule = "abbreviation",
			severity = .Note,
			symbol = "cfg",
			message = "m",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, s, "note: cfg: m\n      [namer/abbreviation]")
}

@(test)
sort_puts_the_serious_first :: proc(t: ^testing.T) {
	findings := []Finding {
		{severity = .Note, file = "b.go", line = 1},
		{severity = .Must_Fix, file = "b.go", line = 9},
		{severity = .Must_Fix, file = "a.go", line = 2},
		{severity = .Must_Fix, file = "a.go", line = 1},
	}
	sort(findings)
	testing.expect_value(t, findings[0].file, "a.go")
	testing.expect_value(t, findings[0].line, 1)
	testing.expect_value(t, findings[1].line, 2)
	testing.expect_value(t, findings[2].line, 9)
	testing.expect_value(t, findings[3].severity, Severity.Note)
	testing.expect(t, must_fix(findings))
	testing.expect(t, !must_fix(findings[3:]))
}

@(test)
id_is_stable_and_matches_the_go_tool :: proc(t: ^testing.T) {
	f := Finding {
		job     = "tests",
		rule    = "cannot-fail",
		file    = "x_test.go",
		line    = 4,
		symbol  = "TestX",
		message = "m",
	}
	identify(&f, context.temp_allocator)
	// sha256("tests\x00cannot-fail\x00x_test.go\x00TestX")[:12], as Go names it.
	testing.expect_value(t, f.id, "52ef4321ce06")
	moved := f
	moved.line = 9
	identify(&moved, context.temp_allocator)
	testing.expect_value(t, moved.id, f.id)
	reworded := f
	reworded.message = "said another way"
	identify(&reworded, context.temp_allocator)
	testing.expect_value(t, reworded.id, f.id)
	other := f
	other.symbol = "TestY"
	identify(&other, context.temp_allocator)
	testing.expect(t, other.id != f.id, "two findings share one id")

	a := Finding {
		job  = "claims",
		rule = "unsupported-claim",
		file = "x.go",
		line = 4,
	}
	b := Finding {
		job  = "claims",
		rule = "unsupported-claim",
		file = "x.go",
		line = 9,
	}
	identify(&a, context.temp_allocator)
	identify(&b, context.temp_allocator)
	testing.expect(t, a.id != b.id, "two comments share one id")

	s1 := Finding {
		job     = "static",
		rule    = "history-coupled-file",
		file    = "a.go",
		message = "ties a.go to b.go",
	}
	s2 := Finding {
		job     = "static",
		rule    = "history-coupled-file",
		file    = "a.go",
		message = "ties a.go to c.go",
	}
	identify(&s1, context.temp_allocator)
	identify(&s2, context.temp_allocator)
	testing.expect(t, s1.id != s2.id, "two partners share one id")
}

@(test)
name_tells_twins_apart :: proc(t: ^testing.T) {
	findings := []Finding {
		{job = "namer", rule = "abbreviation", file = "x.go", symbol = "cfg", severity = .Note},
		{job = "namer", rule = "abbreviation", file = "x.go", symbol = "cfg", severity = .Note},
	}
	name(findings, context.temp_allocator)
	testing.expect(t, findings[0].id != findings[1].id)
	testing.expect(t, strings.has_suffix(findings[1].id, "-2"))
	testing.expect_value(t, findings[0].severity_name, "note")
}

write_source :: proc(t: ^testing.T, name, src: string) -> (dir: string) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	scratch, err := os.make_directory_temp(temp, "review-finding-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no scratch directory")
	}
	path := filepath.join({scratch, name}, context.temp_allocator) or_else name
	testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)
	return scratch
}

@(test)
suppressed_reads_the_dismissal_beside_the_line :: proc(t: ^testing.T) {
	dir := write_source(
		t,
		"x.go",
		"package x\n\n// nothing here\nconst a = 1\n\n//review:" +
		"ignore restates-a-fact the ico package owns the other one\nconst b = 6\n\nconst c = 7\n\nconst d = 8\n\nconst e = 9\n",
	)
	defer os.remove_all(dir)
	Case :: struct {
		name: string,
		f:    Finding,
		want: bool,
		why:  string,
	}
	for c in ([]Case{{"just above", {file = "x.go", line = 7, rule = "restates-a-fact"}, true, "the ico package owns the other one"}, {"on the line", {file = "x.go", line = 6, rule = "restates-a-fact"}, true, "the ico package owns the other one"}, {"distant", {file = "x.go", line = 12, rule = "restates-a-fact"}, false, ""}, {"another rule", {file = "x.go", line = 7, rule = "already-named"}, false, ""}, {"no line", {file = "x.go", rule = "restates-a-fact"}, true, "the ico package owns the other one"}, {"no file", {rule = "restates-a-fact"}, false, ""}, {"missing file", {file = "nowhere.go", line = 1, rule = "restates-a-fact"}, false, ""}}) {
		why, ok := suppressed(c.f, dir, context.temp_allocator)
		testing.expectf(t, ok == c.want, "%s: got %v, want %v", c.name, ok, c.want)
		if ok {
			testing.expectf(t, why == c.why, "%s: reason %q", c.name, why)
		}
	}
}

@(test)
suppressed_reads_all_and_no_reason :: proc(t: ^testing.T) {
	dir := write_source(t, "x.go", "//review:" + "ignore all generated\nconst a = 1\n")
	defer os.remove_all(dir)
	why, ok := suppressed(
		Finding{file = "x.go", line = 2, rule = "anything-at-all"},
		dir,
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, why, "generated")
	other := write_source(
		t,
		"y.go",
		"// review:" + "ignore cannot-fail\nfunc TestX(t *testing.T) {}\n",
	)
	defer os.remove_all(other)
	why, ok = suppressed(
		Finding{file = "y.go", line = 2, rule = "cannot-fail"},
		other,
		context.temp_allocator,
	)
	testing.expect(t, ok, "a space after the slashes still dismisses")
	testing.expect_value(t, why, "no reason given")
}

@(test)
dismissal_needs_the_slashes :: proc(t: ^testing.T) {
	rule, why, found := dismissal("x := 1 //review:" + "ignore no-shadow it is the loop's")
	testing.expect(t, found)
	testing.expect_value(t, rule, "no-shadow")
	testing.expect_value(t, why, "it is the loop's")
	_, _, found = dismissal("review:ignore no-shadow prose")
	testing.expect(t, !found)
	_, _, found = dismissal("//review:" + "ignore")
	testing.expect(t, !found)
	testing.expect_value(t, atoi(" 42 "), 42)
	testing.expect_value(t, atoi("x"), 0)
}
