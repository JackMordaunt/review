package check

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "jm:sh"

import "../change"
import "../finding"
import "../frontend"
import "../tree"
import "../txt"


// dyn is a dynamic array over the items given, for a change built in a
// test.
dyn :: proc(items: []$T) -> [dynamic]T {
	out := make([dynamic]T, context.temp_allocator)
	append(&out, ..items)
	return out
}

// Pair is one case of a table-driven test.
Pair :: struct($K, $V: typeid) {
	key:   K,
	value: V,
}

// coupling is a history in which one file changes with one partner.
coupling :: proc(
	a: string,
	a_commits: int,
	b: string,
	b_commits: int,
	shared: int,
) -> change.Temporal {
	t := change.Temporal {
		commits  = make(map[string]int, context.temp_allocator),
		partners = make(map[string][]change.Partner, context.temp_allocator),
	}
	t.commits[a] = a_commits
	t.commits[b] = b_commits
	partners := make([]change.Partner, 1, context.temp_allocator)
	partners[0] = {b, shared}
	t.partners[a] = partners
	return t
}

// only keeps the findings whose rule opens with the prefix.
only :: proc(findings: []finding.Finding, prefix: string) -> []finding.Finding {
	out := make([dynamic]finding.Finding, context.temp_allocator)
	for f in findings {
		if strings.has_prefix(f.rule, prefix) {
			append(&out, f)
		}
	}
	return out[:]
}

rules_of :: proc(findings: []finding.Finding) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for f in findings {
		append(&names, f.rule)
	}
	return strings.join(names[:], ",", context.temp_allocator)
}

// over runs every check over a change built in the test, with no
// repository behind it.
over :: proc(c: ^change.Change) -> []finding.Finding {
	return run(Scope{c = c}, context.temp_allocator)
}

// added renders a diff adding the lines to one file, in the shape gather
// produces.
added :: proc(file: string, lines: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n", file, len(lines))
	for l in lines {
		fmt.sbprintf(&b, "+%s\n", l)
	}
	return strings.to_string(b)
}

licence_line :: "Copyright 2026 Example Corp. All rights reserved. Licensed under the Apache License, Version 2.0.\n"

good_message :: `review: say which findings the source dismissed

A dismissal answered the finding above it and was then thrown away with
the finding, so a reading that met a third of the change reported less
than it read. Kept beside the finding they answered, a dismissal is
visible where a silent one was not, and --verbose names the reason it
gave rather than leaving a gap in the list for nobody to explain.

The window a dismissal covers stays as written: a few lines either side
of the comment, because narrowing it waits on a case that shows the
narrowing losing a finding it should have kept.`

@(test)
low_entropy_is_reported :: proc(t: ^testing.T) {
	c := change.Change {
		message = strings.repeat("asdf asdf ", 6, context.temp_allocator),
	}
	findings := over(&c)
	testing.expect_value(t, rules_of(findings), "message-low-entropy")
	if len(findings) == 1 {
		f := findings[0]
		testing.expect_value(t, f.job, "static")
		testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
		testing.expect(t, f.verified)
		for want in ([]string{"2.3", "Shannon", "3.2", "phrase repeated"}) {
			testing.expectf(
				t,
				strings.contains(f.message, want),
				"%q missing from: %s",
				want,
				f.message,
			)
		}
	}
}

@(test)
boilerplate_is_reported :: proc(t: ^testing.T) {
	c := change.Change {
		message = strings.repeat(licence_line, 9, context.temp_allocator),
	}
	findings := over(&c)
	testing.expect_value(t, rules_of(findings), "message-boilerplate")
	if len(findings) == 1 {
		for want in ([]string{"compresses", "20%", "pasted"}) {
			testing.expectf(
				t,
				strings.contains(findings[0].message, want),
				"%q missing from: %s",
				want,
				findings[0].message,
			)
		}
	}
	both := change.Change {
		message = strings.repeat("asdf asdf asdf asdf asdf asdf\n", 20, context.temp_allocator),
	}
	testing.expect_value(t, rules_of(over(&both)), "message-low-entropy,message-boilerplate")
}

@(test)
a_message_that_says_something_is_silent :: proc(t: ^testing.T) {
	c := change.Change {
		message = good_message,
	}
	testing.expect_value(t, rules_of(over(&c)), "")
	for msg in ([]string{"wip", strings.repeat(licence_line, 4, context.temp_allocator)}) {
		short := change.Change {
			message = msg,
		}
		testing.expectf(t, len(over(&short)) == 0, "%q: got %v", msg, over(&short))
	}
}

// common_history is a history in which fix and build are common and
// nothing else is.
common_history :: proc(extra: ..string) -> []string {
	h := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 60 {
		append(&h, "fix the failing build", "build: fix the build", "fix build")
	}
	for _ in 0 ..< 40 {
		append(&h, ..extra)
	}
	return h[:]
}

@(test)
common_words_are_reported :: proc(t: ^testing.T) {
	c := change.Change {
		message = "fix build",
		history = common_history(),
		files   = {"auth_service.go"},
		diff    = "+type JWTParser struct{}\n",
	}
	findings := over(&c)
	testing.expect_value(t, rules_of(findings), "message-common-words")
	if len(findings) == 1 {
		for want in ([]string{"fix", "build", "180", "names nothing"}) {
			testing.expectf(
				t,
				strings.contains(findings[0].message, want),
				"%q missing from: %s",
				want,
				findings[0].message,
			)
		}
	}
}

@(test)
common_words_are_spared :: proc(t: ^testing.T) {
	// A word the history has not used; the change named; a version
	// number; a thin history; git's own subjects.
	unused := change.Change {
		message = "fix the parser deadlock",
		history = common_history(),
		files   = {"auth_service.go"},
	}
	testing.expect_value(t, rules_of(over(&unused)), "")
	named := change.Change {
		message = "update parser",
		history = common_history("update the parser", "parser: update"),
		files   = {"parser.go"},
		diff    = "+func Parse() {}\n",
	}
	testing.expect_value(t, rules_of(over(&named)), "")
	version := change.Change {
		message = "bump to 2.0.26",
		history = common_history("bump version"),
		files   = {"version.go"},
	}
	testing.expect_value(t, rules_of(over(&version)), "")
	thin := change.Change {
		message = "fix build",
		history = common_history()[:99],
		files   = {"auth_service.go"},
	}
	testing.expect_value(t, rules_of(over(&thin)), "")
	for msg in ([]string{"Merge branch 'main' into dev", "Squashed 'vendor/x/' content from branch main"}) {
		merge := change.Change {
			message = msg,
			history = common_history(),
		}
		testing.expectf(t, len(over(&merge)) == 0, "%q: got %v", msg, over(&merge))
	}
}

@(test)
venting_is_reported :: proc(t: ^testing.T) {
	for msg in ([]string{"whoops", "oops, missed a comma", "damn, ran the formatter with spaces instead of tabs", "WHOOPS, left the debug print in"}) {
		c := change.Change {
			message = msg,
		}
		findings := over(&c)
		testing.expectf(
			t,
			rules_of(findings) == "message-frustration",
			"%q: got %v",
			msg,
			findings,
		)
		if len(findings) == 1 {
			testing.expect(t, strings.contains(findings[0].message, "exclamation"))
		}
	}
	for msg in ([]string{"Change >> behaviour in LLVM to prevent stupid UB", "Respect TERM=dumb in the test runner", "Implement dumb PtrMap", "Temporarily fix the syscall (eventually to be replaced)", "finally fixed the flaky resize test"}) {
		c := change.Change {
			message = msg,
		}
		testing.expectf(
			t,
			len(only(over(&c), "message-frustration")) == 0,
			"%q: got %v",
			msg,
			over(&c),
		)
	}
}

@(test)
mood_is_checked_and_spared :: proc(t: ^testing.T) {
	for msg in ([]string{"Added readme.", "Fixing the build", "This fixes the crash", "i can't spell", "web: solarized palette at artifact-page contrast", "deps: upgraded the webp"}) {
		c := change.Change {
			message = msg,
		}
		findings := over(&c)
		testing.expectf(
			t,
			rules_of(findings) == "message-not-imperative",
			"%q: got %v",
			msg,
			findings,
		)
		if len(findings) == 1 {
			testing.expect(t, strings.contains(findings[0].message, "imperative mood"))
		}
	}
	for msg in ([]string{"review: measure the message without a model", "icnsify: read icons out of a Windows binary", "Add caching for responses", "Bump to 2.0.x", "review: an eval set, and the criteria tuned against it", "docs: the vocabulary, the voices section, and the three providers", "Speed up the build", "Merge branch 'main' into dev", "Squashed 'vendor/x/' content from branch main"}) {
		c := change.Change {
			message = msg,
		}
		testing.expectf(t, len(over(&c)) == 0, "%q: got %v", msg, over(&c))
	}
}

varied_words :: proc(n: int) -> string {
	words := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< n {
		append(&words, fmt.tprintf("word%d", i))
	}
	return strings.join(words[:], " ", context.temp_allocator)
}

@(test)
body_is_owed_spared_and_capped :: proc(t: ^testing.T) {
	owed := change.Change {
		message = "feat: add the thing",
		diff    = strings.repeat("+line\n", 51, context.temp_allocator),
	}
	findings := over(&owed)
	testing.expect_value(t, rules_of(findings), "message-no-body")
	if len(findings) == 1 {
		testing.expect(t, strings.contains(findings[0].message, "carries no body"))
	}
	Case :: struct {
		diff, subject, body: string,
	}
	for c in ([]Case{{strings.repeat("+line\n", 10, context.temp_allocator), "feat: add the thing", ""}, {strings.repeat("+line\n", 500, context.temp_allocator), "feat: add the thing", "one two three four five"}, {strings.repeat("+line\n", 500, context.temp_allocator), "feat: add the thing", varied_words(150)}, {strings.repeat("+line\n", 500, context.temp_allocator), "Merge branch 'main'", ""}, {strings.concatenate({strings.repeat("+x\n", 30, context.temp_allocator), strings.repeat("-x\n", 30, context.temp_allocator)}, context.temp_allocator), "format: run gofmt", ""}}) {
		msg := c.subject
		if c.body != "" {
			msg = strings.concatenate({c.subject, "\n\n", c.body}, context.temp_allocator)
		}
		spared := change.Change {
			message = msg,
			diff    = c.diff,
		}
		testing.expectf(t, len(over(&spared)) == 0, "%q: got %v", c.subject, over(&spared))
	}
	capped := change.Change {
		message = strings.concatenate(
			{"feat: add the thing\n\n", varied_words(151)},
			context.temp_allocator,
		),
		diff    = strings.repeat("+line\n", 10, context.temp_allocator),
	}
	testing.expect_value(t, rules_of(over(&capped)), "message-long-body")
}

@(test)
temporal_is_reported_and_spared :: proc(t: ^testing.T) {
	coupled := coupling("login.go", 10, "session.go", 9, 9)
	c := change.Change {
		files    = {"login.go"},
		temporal = coupled,
	}
	findings := over(&c)
	testing.expect_value(t, rules_of(findings), "history-coupled-file")
	if len(findings) == 1 {
		for want in ([]string{"login.go", "session.go", "9 of the 10"}) {
			testing.expectf(
				t,
				strings.contains(findings[0].message, want),
				"%q missing from: %s",
				want,
				findings[0].message,
			)
		}
		testing.expect_value(t, findings[0].file, "login.go")
	}
	touched := change.Change {
		files    = {"login.go", "session.go"},
		temporal = coupled,
	}
	testing.expect_value(t, rules_of(over(&touched)), "")
	weak := change.Change {
		files    = {"a.go"},
		temporal = coupling("a.go", 10, "b.go", 10, 5),
	}
	testing.expect_value(t, rules_of(over(&weak)), "")
	thin := change.Change {
		files    = {"a.go"},
		temporal = coupling("a.go", 3, "b.go", 3, 3),
	}
	testing.expect_value(t, rules_of(over(&thin)), "")
}

@(test)
brand_shaped_words_are_not_identifiers :: proc(t: ^testing.T) {
	for p in ([]Pair(string, bool){{"gRPC", true}, {"iOS", true}, {"macOS", true}, {"eBay", true}, {"getID", false}, {"parseConfig", false}, {"readURL", false}, {"id", false}}) {
		testing.expectf(t, brand_shaped(p.key) == p.value, "%s: %v", p.key, brand_shaped(p.key))
	}
	names := find_all(
		identifier_shaped,
		"x: add `load_settings` and parseConfig() for docs/notes.md",
	)
	testing.expect_value(
		t,
		fmt.tprint(names),
		"[\"`load_settings`\", \"parseConfig\", \"docs/notes.md\"]",
	)
}

@(test)
suppression_added_is_reported :: proc(t: ^testing.T) {
	// The ignore comment is assembled at runtime so this file does not
	// add a dismissal of its own.
	diff := strings.concatenate(
		{
			"--- a/ico.go\n+++ b/ico.go\n@@ -1,3 +1,5 @@\n package ico\n+//review:",
			"ignore cannot-fail the test can fail\n+//review:",
			"ignore <rule> <why>\n func f() {}\n",
		},
		context.temp_allocator,
	)
	c := change.Change {
		diff = diff,
	}
	findings := collect(Scope{c = &c}, check_suppression_added, context.temp_allocator)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		f := findings[0]
		testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
		testing.expect(t, strings.contains(f.message, "ico.go:2 (cannot-fail)"))
		testing.expect(
			t,
			!strings.contains(f.message, "<rule>"),
			"counted a documented placeholder",
		)
		testing.expect_value(t, f.file, "")
	}
	prose := change.Change {
		diff = strings.concatenate(
			{
				"--- a/readme.md\n+++ b/readme.md\n@@ -1,3 +1,4 @@\n # review\n+`//review:",
				"ignore <rule> <why>`\n done\n",
			},
			context.temp_allocator,
		),
	}
	testing.expect_value(
		t,
		len(collect(Scope{c = &prose}, check_suppression_added, context.temp_allocator)),
		0,
	)
	both := change.Change {
		diff = strings.concatenate(
			{
				"--- a/x_test.go\n+++ b/x_test.go\n@@ -1,2 +1,2 @@\n package x\n+//review:",
				"ignore all tidy\n-func TestA(t *testing.T) {}\n",
			},
			context.temp_allocator,
		),
	}
	got := over(&both)
	testing.expect_value(t, rules_of(got), "suppression-added,test-deleted")
	for f in got {
		testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
	}
}

@(test)
deleted_tests_are_reported :: proc(t: ^testing.T) {
	c := change.Change {
		diff = "--- a/ico_test.go\n+++ b/ico_test.go\n@@ -1,5 +1,4 @@\n package ico\n-func TestAssemble(t *testing.T) {}\n-func TestWrite(t *testing.T) {}\n+func TestAssembleIcons(t *testing.T) {}\n func f() {}\n",
	}
	findings := collect(Scope{c = &c}, check_deleted_tests, context.temp_allocator)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		f := findings[0]
		testing.expect_value(t, f.rule, "test-deleted")
		testing.expect_value(t, f.file, "ico_test.go")
		testing.expect(t, strings.contains(f.message, "TestWrite"))
		testing.expect(
			t,
			!strings.contains(f.message, "TestAssemble"),
			"the rename was counted as a deletion",
		)
		testing.expect(t, strings.contains(f.fix, "test-deleted"))
	}
	js := change.Change {
		diff = "--- a/web/app.test.ts\n+++ b/web/app.test.ts\n@@ -1,4 +1 @@\n import { it } from \"testing\";\n-it.skip(\"parses icons\", () => {});\n-describe(\"loads\", () => {});\n+export {};\n",
	}
	got := collect(Scope{c = &js}, check_deleted_tests, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect(t, strings.contains(got[0].message, "parses icons"))
		testing.expect(t, strings.contains(got[0].message, "loads"))
	}
	outside := change.Change {
		diff = "--- a/ico.go\n+++ b/ico.go\n@@ -1,3 +1,2 @@\n package ico\n-func TestWrite(w io.Writer) {}\n-func helper() {}\n+func helper() {}\n",
	}
	testing.expect_value(
		t,
		len(collect(Scope{c = &outside}, check_deleted_tests, context.temp_allocator)),
		0,
	)
	inside := change.Change {
		diff = "--- a/ico_test.go\n+++ b/ico_test.go\n@@ -1,3 +1,2 @@\n package ico\n-func TestWrite(t *testing.T) {}\n-func helper() {}\n+func helper() {}\n",
	}
	testing.expect_value(
		t,
		len(collect(Scope{c = &inside}, check_deleted_tests, context.temp_allocator)),
		1,
	)
}

@(test)
covered_spares_a_rename :: proc(t: ^testing.T) {
	testing.expect(t, covered("TestParseIcons", {"TestParseIconsV2", "TestWrite"}))
	testing.expect(t, !covered("TestParseIcons", {"TestParse", "TestWrite"}))
	testing.expect(t, !covered("TestV2", {"TestV2"}))
	for p in ([]Pair(string, string){{`Deno.test("deno string", () => {`, "deno string"}, {`Deno.test.ignore("deno ignored", () => {`, "deno ignored"}, {`  test.skip("bun skipped", () => {`, "bun skipped"}, {`it.only("focused", () => {`, "focused"}, {`test('node plain', { timeout: 5 }, () => {`, "node plain"}, {`test.concurrent.only("both", async () => {`, "both"}, {`describe("suite", () => {`, "suite"}, {`Deno.test({ name: "object", fn() {`, ""}, {`const test = 1;`, ""}, {`func TestX(t *testing.T) {`, "TestX"}, {`async def test_it(self):`, "test_it"}}) {
		testing.expectf(
			t,
			removed_test_name(p.key) == p.value,
			"%q: got %q, want %q",
			p.key,
			removed_test_name(p.key),
			p.value,
		)
	}
	for path in ([]string{"ico_test.go", "web/app.test.ts", "web/app.spec.js", "tests/x.py", "test_x.py"}) {
		testing.expectf(t, is_test_file(path), "%s is a test file", path)
	}
	for path in ([]string{"ico.go", "web/app.ts", "src/lib.rs"}) {
		testing.expectf(t, !is_test_file(path), "%s is not a test file", path)
	}
}

@(test)
names_are_measured :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Stutter :: struct {
		s:     change.Symbol,
		fires: bool,
	}
	for c in ([]Stutter{{{name = "IcoEntry", pkg = "ico", exported = true, file = "ico/ico.go"}, true}, {{name = "exe_kind", pkg = "exe", exported = true, file = "exe/exe.odin"}, true}, {{name = "Time", pkg = "time", exported = true, file = "time/time.go"}, false}, {{name = "Entry", pkg = "ico", exported = true, file = "ico/ico.go"}, false}, {{name = "icoEntry", pkg = "ico", exported = false, file = "ico/ico.go"}, false}, {{name = "MainLoop", pkg = "main", exported = true, file = "main.go"}, false}, {{name = "Iconic", pkg = "ico", exported = true, file = "ico/ico.go"}, false}}) {
		out := make([dynamic]finding.Finding, context.temp_allocator)
		stutter(c.s, &out)
		testing.expectf(t, (len(out) == 1) == c.fires, "%s in %s: %v", c.s.name, c.s.pkg, out)
	}
	for c in ([]Stutter{{{name = "len", file = "x.go"}, true}, {{name = "url", file = "x.go"}, true}, {{name = "Promise", file = "x.ts"}, true}, {{name = "render", file = "x.go"}, false}, {{name = "len", file = "x.ts"}, false}, {{name = "Promise", file = "x.go"}, false}}) {
		out := make([dynamic]finding.Finding, context.temp_allocator)
		shadow(c.s, &out)
		testing.expectf(t, (len(out) == 1) == c.fires, "%s in %s: %v", c.s.name, c.s.file, out)
	}
	for p in ([]Pair(string, bool){{"loadCfg", true}, {"user_mgr", true}, {"BtnLabel", true}, {"msgCount", false}, {"parseURL", false}, {"ctx", false}, {"configure", false}}) {
		out := make([dynamic]finding.Finding, context.temp_allocator)
		abbreviated(change.Symbol{name = p.key, file = "x.go"}, &out)
		testing.expectf(t, (len(out) == 1) == p.value, "%s: %v", p.key, out)
	}
	c := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{name = "IcoEntry", pkg = "ico", exported = true, file = "ico/ico.go", line = 3},
				{name = "cfg", file = "ico/ico.go", line = 9},
				{name = "cfgForTests", file = "ico/ico_test.go", line = 4},
			},
		),
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &c}, check_names, context.temp_allocator)),
		"no-stutter,abbreviation",
	)
	testing.expect_value(
		t,
		fmt.tprint(txt.split_words("parseHTTPRequest_now", context.temp_allocator)),
		`["parse", "H", "T", "T", "P", "Request", "now"]`,
	)
}

@(test)
leftovers_are_reported :: proc(t: ^testing.T) {
	Debug :: struct {
		file, line: string,
		severity:   finding.Severity,
		fires:      bool,
	}
	for c in ([]Debug{{"a.ts", "  debugger;", .Consider, true}, {"a.tsx", "  console.log(x)", .Note, true}, {"a.py", "breakpoint()", .Consider, true}, {"a.rs", "let y = dbg!(x);", .Consider, true}, {"a.go", "spew.Dump(x)", .Consider, true}, {"a.go", `fmt.Println("DEBUG", x)`, .Consider, true}, {"a.go", `fmt.Println("done")`, .Note, false}, {"a.go", "debugger := newDebugger()", .Note, false}, {"a.md", "  debugger;", .Note, false}}) {
		ch := change.Change {
			diff = added(c.file, c.line),
		}
		got := collect(Scope{c = &ch}, check_debug_leftovers, context.temp_allocator)
		testing.expectf(t, (len(got) == 1) == c.fires, "%s %q: %v", c.file, c.line, got)
		if len(got) == 1 && c.fires {
			testing.expect_value(t, got[0].severity, c.severity)
		}
	}
	todos := change.Change {
		comments = dyn(
			[]change.Located {
				{text = "TODO handle the empty case", file = "a.go", line = 1},
				{text = "TODO(jack) handle the empty case", file = "a.go", line = 2},
				{text = "FIXME see #42", file = "a.go", line = 3},
				{text = "HACK until PROJ-12 lands", file = "a.go", line = 4},
				{text = "the todo list is rendered here", file = "a.go", line = 5},
			},
		),
	}
	got := collect(Scope{c = &todos}, check_todos, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].line, 1)
	}
	commented := change.Change {
		comments = dyn(
			[]change.Located {
				{text = "x := parse(input);", file = "a.go", line = 1},
				{text = "returns the name (see below)", file = "a.go", line = 5},
				{text = "if err != nil {", file = "a.go", line = 10},
				{text = "return err", file = "a.go", line = 11},
				{text = "}", file = "a.go", line = 12},
				{text = "for the record:", file = "a.go", line = 20},
				{text = "go:generate stringer -type=Kind", file = "a.go", line = 30},
			},
		),
	}
	code := collect(Scope{c = &commented}, check_commented_code, context.temp_allocator)
	testing.expect_value(t, len(code), 2)
	if len(code) == 2 {
		testing.expect_value(t, code[0].line, 1)
		testing.expect_value(t, code[1].line, 10)
	}
	Swallowed :: struct {
		file:  string,
		lines: []string,
		fires: bool,
	}
	for c in ([]Swallowed{{"a.go", {"_ = err"}, true}, {"a.go", {"_, err := f()", "if err != nil {", "\treturn err", "}"}, false}, {"a.ts", {"try { f() } catch (e) {}"}, true}, {"a.ts", {"} catch (e) {", "}"}, true}, {"a.ts", {"} catch (e) {", "  log(e)", "}"}, false}, {"a.js", {"p.catch(() => {})"}, true}, {"a.py", {"except ValueError:", "    pass"}, true}, {"a.py", {"except ValueError: pass"}, true}, {"a.py", {"except ValueError:", "    raise"}, false}}) {
		ch := change.Change {
			diff = added(c.file, ..c.lines),
		}
		found := collect(Scope{c = &ch}, check_swallowed_errors, context.temp_allocator)
		testing.expectf(t, (len(found) == 1) == c.fires, "%s %v: %v", c.file, c.lines, found)
	}
}

// body is a Go function long enough to compare, built from a name and
// the names of the two values it works on.
body :: proc(name, a, b: string) -> string {
	return fmt.tprintf(
		`func %s(%s []int, %s int) int {
	total := 0
	for _, v := range %s {
		if v > %s {
			total += v
		} else if v == %s {
			total -= v
		} else {
			total++
		}
	}
	if total < 0 {
		return -total
	}
	if total > 1000 {
		return 1000
	}
	for i := 0; i < len(%s); i++ {
		total += i * 2
	}
	return total
}`,
		name,
		a,
		b,
		a,
		b,
		b,
		a,
	)
}

// small is a wrapper of the shape every wrapper has, too short for a match
// in shape to mean anything, though long enough for an exact copy to.
small :: proc(name, kind: string) -> string {
	return fmt.tprintf(
		`func %s(raw string) (%s, error) {
	var r %s
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return %s{}, fmt.Errorf("reading the answer: %%w", err)
	}
	return r, nil
}`,
		name,
		kind,
		kind,
		kind,
	)
}

@(test)
clones_are_found :: proc(t: ^testing.T) {
	exact := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "sumAbove",
					kind = "func",
					file = "b.go",
					line = 10,
					body = body("sumAbove", "xs", "floor"),
				},
			},
		),
		index   = {
			{
				name = "sumAll",
				kind = "func",
				file = "a.go",
				line = 3,
				body = body("sumAll", "xs", "floor"),
			},
		},
	}
	got := collect(Scope{c = &exact}, check_clones, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].rule, "duplicate-body")
		testing.expect_value(t, got[0].severity, finding.Severity.Must_Fix)
		testing.expect(t, strings.contains(got[0].message, "a.go:3"))
		testing.expect_value(t, got[0].symbol, "sumAbove")
	}
	shape := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "sumAbove",
					kind = "func",
					file = "b.go",
					line = 10,
					body = body("sumAbove", "rows", "limit"),
				},
			},
		),
		index   = {
			{
				name = "sumAll",
				kind = "func",
				file = "a.go",
				line = 3,
				body = body("sumAll", "xs", "floor"),
			},
		},
	}
	got = collect(Scope{c = &shape}, check_clones, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].severity, finding.Severity.Consider)
	}
	twice := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "one",
					kind = "func",
					file = "a.go",
					line = 3,
					body = body("one", "xs", "floor"),
				},
				{
					name = "two",
					kind = "func",
					file = "a.go",
					line = 30,
					body = body("two", "xs", "floor"),
				},
			},
		),
	}
	got = collect(Scope{c = &twice}, check_clones, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].symbol, "two")
	}
	small_or_different := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "Size",
					kind = "func",
					file = "b.go",
					line = 10,
					body = "func (e Entry) Size() int { return e.size }",
				},
				{
					name = "other",
					kind = "func",
					file = "b.go",
					line = 20,
					body = strings.concatenate(
						{body("other", "xs", "floor"), "\n// and more\nvar _ = 1"},
						context.temp_allocator,
					),
				},
			},
		),
		index   = {
			{
				name = "Len",
				kind = "func",
				file = "a.go",
				line = 3,
				body = "func (e Entry) Len() int { return e.size }",
			},
			{
				name = "sumAll",
				kind = "func",
				file = "a.go",
				line = 3,
				body = body("sumAll", "xs", "floor"),
			},
		},
	}
	testing.expect_value(
		t,
		len(collect(Scope{c = &small_or_different}, check_clones, context.temp_allocator)),
		0,
	)
	wrapper := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "decodeB",
					kind = "func",
					file = "b.go",
					line = 10,
					body = small("decodeB", "verdicts"),
				},
			},
		),
		index   = {
			{
				name = "decodeA",
				kind = "func",
				file = "a.go",
				line = 3,
				body = small("decodeA", "reported"),
			},
		},
	}
	testing.expect_value(
		t,
		len(collect(Scope{c = &wrapper}, check_clones, context.temp_allocator)),
		0,
	)
	wrapper.symbols[0].body = small("decodeB", "reported")
	copied := collect(Scope{c = &wrapper}, check_clones, context.temp_allocator)
	testing.expect_value(t, len(copied), 1)
	if len(copied) == 1 {
		testing.expect_value(t, copied[0].severity, finding.Severity.Must_Fix)
	}
}

@(test)
normalise_reads_through_comments_and_space :: proc(t: ^testing.T) {
	a := normalise(body("f", "xs", "n"), "f", "go", context.temp_allocator)
	with_comment, _ := strings.replace_all(
		body("f", "xs", "n"),
		"total := 0",
		"total := 0 // start\n\n",
		context.temp_allocator,
	)
	b := normalise(with_comment, "f", "go", context.temp_allocator)
	testing.expect_value(t, a.exact, b.exact)
	testing.expect(t, strings.contains(a.exact, "NAME"))
	testing.expect(t, !strings.contains(a.exact, " f "))
	testing.expect(t, strings.contains(a.structural, "for ID , ID := range ID"))
	toks := lexemes(`x := a.b(0x1F, 2.5, "s\"t", 'c') // c`, context.temp_allocator)
	testing.expect_value(
		t,
		fmt.tprint(toks),
		`["x", ":=", "a", ".", "b", "(", "0x1F", ",", "2.5", ",", "\"s\\\"t\"", ",", "'c'", ")", "/", "/", "c"]`,
	)
	testing.expect_value(
		t,
		strip_comments("a // b\n  # c\nd /* e */ f \"//x\"", context.temp_allocator),
		"a  \n   \nd   f \"//x\"",
	)
}

@(test)
shape_prose_and_formatting_are_measured :: proc(t: ^testing.T) {
	deep := "func f() {\n\tif a {\n\t\tfor b {\n\t\t\tif c {\n\t\t\t\tswitch d {\n\t\t\t\tcase 1:\n\t\t\t\t\tif e {\n\t\t\t\t\t\tif g { x := \"{\" }\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}"
	testing.expect_value(t, nesting(deep), 6)
	testing.expect_value(t, nesting("func f() { return 1 }"), 0)
	testing.expect_value(t, line_count("a\nb\nc"), 3)
	c := change.Change {
		symbols = dyn(
			[]change.Symbol{{name = "f", kind = "func", file = "a.go", line = 1, body = deep}},
		),
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &c}, check_shape, context.temp_allocator)),
		"nesting-too-deep",
	)
	long := change.Change {
		symbols = dyn(
			[]change.Symbol {
				{
					name = "g",
					kind = "func",
					file = "a.go",
					line = 1,
					body = strings.repeat("x\n", 151, context.temp_allocator),
				},
			},
		),
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &long}, check_shape, context.temp_allocator)),
		"function-too-long",
	)

	testing.expect(
		t,
		restates(change.Located{text = "parse the input", below = "func parseInput(x) {\nreturn"}),
	)
	testing.expect(
		t,
		!restates(
			change.Located{text = "parse the input carefully", below = "func parseInput(x) {"},
		),
	)
	testing.expect(t, !restates(change.Located{text = "parse", below = "func parse() {"}))
	testing.expect(
		t,
		!restates(change.Located{text = "TODO parse the input", below = "func parseInput() {"}),
	)
	testing.expect(
		t,
		directive("go:generate x") && directive("see https://x") && !directive("plain prose"),
	)
	prose := change.Change {
		comments = dyn(
			[]change.Located {
				{
					text = "parse the input",
					file = "a.go",
					line = 3,
					below = "func parseInput(x) {",
				},
			},
		),
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &prose}, check_restating, context.temp_allocator)),
		"comment-restates-code",
	)

	mixed := change.Change {
		changed    = 100,
		whitespace = 60,
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &mixed}, check_formatting, context.temp_allocator)),
		"formatting-mixed-in",
	)
	pure := change.Change {
		changed    = 100,
		whitespace = 95,
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &pure}, check_formatting, context.temp_allocator)),
		"",
	)
	little := change.Change {
		changed    = 30,
		whitespace = 10,
	}
	testing.expect_value(
		t,
		rules_of(collect(Scope{c = &little}, check_formatting, context.temp_allocator)),
		"",
	)
}

@(test)
tests_are_measured :: proc(t: ^testing.T) {
	testing.expect(
		t,
		assertless(
			change.Function {
				name = "TestX",
				file = "a_test.go",
				body = "func TestX(t *testing.T) {\n\tf()\n}",
			},
		),
	)
	testing.expect(
		t,
		!assertless(
			change.Function {
				name = "TestX",
				file = "a_test.go",
				body = "func TestX(tc *testing.T) {\n\ttc.Fatal(1)\n}",
			},
		),
	)
	testing.expect(
		t,
		!assertless(
			change.Function {
				name = "TestX",
				file = "a_test.go",
				body = "func TestX(t *testing.T) {\n\thelper(t, 1)\n}",
			},
		),
	)
	testing.expect(
		t,
		!assertless(
			change.Function {
				name = "BenchmarkX",
				file = "a_test.go",
				body = "func BenchmarkX(b *testing.B) {}",
			},
		),
	)
	testing.expect(
		t,
		assertless(
			change.Function {
				name = "reads",
				file = "a.test.ts",
				body = "test('reads', () => { f() })",
			},
		),
	)
	testing.expect(
		t,
		!assertless(
			change.Function {
				name = "reads",
				file = "a.test.ts",
				body = "test('reads', () => { expect(f()).toBe(1) })",
			},
		),
	)
	testing.expect(
		t,
		assertless(
			change.Function {
				name = "x",
				file = "a_test.odin",
				body = "x :: proc(t: ^testing.T) { f() }",
			},
		),
	)
	testing.expect(
		t,
		!assertless(
			change.Function {
				name = "x",
				file = "a_test.odin",
				body = "x :: proc(t: ^testing.T) { testing.expect(t, f()) }",
			},
		),
	)
	for p in ([]Pair(string, string){{"assert.True(t, true)", "a constant"}, {"require.NoError(t, nil)", "a constant"}, {"if got != got {", "a value against itself"}, {"assert 1 == 1", "a constant"}, {"self.assertTrue(True)", "a constant"}, {"expect(true).toBe(true)", "a constant"}, {"expect(1).toEqual(1)", "a constant"}, {"expect(x.name).toBe(x.name)", "a value against itself"}, {"assert!(true);", "a constant"}, {"assert_eq!(2, 2);", "a constant"}, {"testing.expect(t, true)", "a constant"}, {"assert_eq!(a, a);", "a value against itself"}, {"assert.Equal(t, x, x)", "a value against itself"}, {"assert.Equal(t, got, want)", ""}, {"if got != want {", ""}, {"// assert.True(t, true) is what not to write", ""}, {"expect(x).toBe(y)", ""}}) {
		testing.expectf(
			t,
			tautological(p.key) == p.value,
			"%q: got %q, want %q",
			p.key,
			tautological(p.key),
			p.value,
		)
	}
	c := change.Change {
		tests = dyn(
			[]change.Function {
				{
					name = "TestX",
					file = "x_test.go",
					line = 10,
					body = "func TestX(t *testing.T) {\n\tassert.True(t, true)\n}",
				},
				{
					name = "TestY",
					file = "x_test.go",
					line = 20,
					body = "func TestY(t *testing.T) {\n\tf()\n}",
				},
			},
		),
	}
	got := over(&c)
	testing.expect_value(t, rules_of(got), "test-no-assertion,assertion-always-true")
	if len(got) == 2 {
		testing.expect_value(t, got[1].line, 11)
		testing.expect_value(t, got[1].symbol, "TestX")
	}
}

@(test)
references_are_searched_as_whole_words :: proc(t: ^testing.T) {
	sources := make(map[string][]byte, context.temp_allocator)
	sources["a.go"] = transmute([]byte)string("package x\n\nfunc Waiting() int { return 2 }\n")
	sources["b.go"] = transmute([]byte)string("var _ = WaitingRoom\n")
	testing.expect(
		t,
		!referenced(change.Symbol{name = "Waiting", file = "a.go", line = 3}, sources),
		"a prefix of another word counted",
	)
	sources["c.go"] = transmute([]byte)string("var _ = Waiting()\n")
	testing.expect(
		t,
		referenced(change.Symbol{name = "Waiting", file = "a.go", line = 3}, sources),
		"a call was not counted",
	)
	sources["c.go"] = transmute([]byte)string("// Waiting is documented here\n")
	testing.expect(
		t,
		!referenced(change.Symbol{name = "Waiting", file = "a.go", line = 3}, sources),
		"a comment counted",
	)

	testing.expect(
		t,
		called_by_the_runtime(change.Symbol{name = "MarshalJSON", kind = "func", file = "a.go"}),
	)
	testing.expect(
		t,
		called_by_the_runtime(
			change.Symbol {
				name = "DllGetClassObject",
				kind = "func",
				file = "a.go",
				doc = "DllGetClassObject answers COM.\n\nexport DllGetClassObject",
			},
		),
	)
	testing.expect(
		t,
		!called_by_the_runtime(
			change.Symbol {
				name = "DllInstall",
				kind = "func",
				file = "a.go",
				doc = "export DllGetClassObject",
			},
		),
	)
	testing.expect(
		t,
		!called_by_the_runtime(change.Symbol{name = "String", kind = "value", file = "a.go"}),
	)
	desc, ok := describe("go-vet/nilness")
	testing.expect(t, ok && strings.contains(desc, "go vet"))
	_, ok = describe("no-such-rule")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(catalogue(context.temp_allocator), "`test-deleted`"))
}

// new_repo makes a repository with one commit holding go.mod, x.go and
// x_test.go, for the checks that read the tree.
new_repo :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	scratch, err := os.make_directory_temp(temp, "review-check-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no scratch directory")
	}
	root = scratch
	ok = git(root, "init", "-q")
	ok &&= write(root, "go.mod", "module x\n\ngo 1.27.0\n")
	ok &&= write(root, "x.go", "package x\n")
	ok &&= write(root, "x_test.go", "package x\n")
	ok &&= git(root, "add", "go.mod", "x.go", "x_test.go")
	ok &&= git(root, "commit", "-q", "-m", "first")
	return root, ok
}

git :: proc(root: string, args: ..string) -> bool {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false")
	append(&argv, ..args)
	return sh.exec(argv[:], {dir = root}, context.temp_allocator).ok
}

write :: proc(root, name, src: string) -> bool {
	path := filepath.join({root, name}, context.temp_allocator) or_else name
	return os.write_entire_file(path, transmute([]byte)src) == nil
}

// staged gathers the staged change of a repository and reads it, for a
// check that needs the whole tree.
staged :: proc(t: ^testing.T, root: string) -> (c: ^change.Change, s: Scope) {
	c = new(change.Change, context.temp_allocator)
	gathered: bool
	c^, gathered = change.gather("", root, context.temp_allocator)
	testing.expect(t, gathered, "gather")
	tr, at_ok := tree.at(root, "", context.temp_allocator)
	testing.expect(t, at_ok)
	change.read(c, tr, context.temp_allocator)
	c.index, _ = change.index(tr, context.temp_allocator)
	return c, scope_of(c, tr, context.temp_allocator)
}

@(test)
unreferenced_reads_the_whole_tree :: proc(t: ^testing.T) {
	if !frontend.installed(.Go) {
		testing.fail_now(t, "review-go is not on the path")
	}
	root, made := new_repo(t)
	testing.expect(t, made)
	defer os.remove_all(root)
	testing.expect(
		t,
		write(
			root,
			"x.go",
			"package x\n\n// Used is called from the template below.\nfunc Used() int { return 1 }\n\n// Waiting is called from nowhere.\nfunc Waiting() int { return 2 }\n\nfunc lonely() int { return 3 }\n",
		),
	)
	testing.expect(t, write(root, "page.tmpl", "{{ Used }}\n"))
	testing.expect(t, git(root, "add", "x.go", "page.tmpl"))
	_, s := staged(t, root)
	got := collect(s, check_unreferenced, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].rule, "new-symbol-unreferenced")
		testing.expect_value(t, got[0].file, "x.go")
		testing.expect(t, strings.contains(got[0].message, "Waiting"))
		testing.expect(t, strings.contains(got[0].message, "lonely"))
		testing.expect(
			t,
			!strings.contains(got[0].message, "Used"),
			"a name the template uses was reported",
		)
	}
}

@(test)
code_without_tests_is_reported_where_tests_are_kept :: proc(t: ^testing.T) {
	if !frontend.installed(.Go) {
		testing.fail_now(t, "review-go is not on the path")
	}
	root, made := new_repo(t)
	testing.expect(t, made)
	defer os.remove_all(root)
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, "package x\n\n")
	for i in 0 ..< 60 {
		append(&parts, fmt.tprintf("var v%d = %d\n", i, i))
	}
	testing.expect(t, write(root, "x.go", strings.concatenate(parts[:], context.temp_allocator)))
	testing.expect(t, git(root, "add", "x.go"))
	c, s := staged(t, root)
	c.message = "x: add sixty variables"
	got := over_scope(s)
	testing.expect_value(t, rules_of(only(got, "code-without")), "code-without-tests")
	testing.expect_value(t, rules_of(only(got, "message-")), "message-no-body")
	names := only(got, "message-names")
	testing.expect_value(t, len(names), 0)

	testing.expect(t, write(root, "x_test.go", "package x\n\n// touched\n"))
	testing.expect(t, git(root, "add", "x_test.go"))
	_, again := staged(t, root)
	testing.expect_value(
		t,
		len(collect(again, check_code_without_tests, context.temp_allocator)),
		0,
	)
}

over_scope :: proc(s: Scope) -> []finding.Finding {
	return run(s, context.temp_allocator)
}

@(test)
dismissals_are_counted_per_rule :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	sources := make(map[string][]byte)
	sources["a.go"] = transmute([]byte)strings.concatenate(
		{
			"package a\n//review:",
			"ignore no-shadow the loop's\nvar x = 1\n// review:",
			"ignore no-shadow\n",
		},
	)
	sources["b_test.go"] = transmute([]byte)strings.concatenate(
		{"const fixture = \"//review:", "ignore cannot-fail it can\\nconst b = 6\"\n"},
	)
	sources["readme.md"] = transmute([]byte)strings.concatenate(
		{"`//review:", "ignore <rule> <why>`\n"},
	)
	out := dismissals(Scope{sources = sources})
	testing.expect(t, strings.has_prefix(out, "no-shadow                    2\n"), out)
	testing.expect(t, strings.contains(out, "    a.go:2  the loop's\n"), out)
	testing.expect(t, strings.contains(out, "    a.go:4  no reason given\n"), out)
	testing.expect(
		t,
		strings.contains(out, "cannot-fail                  1\n    b_test.go:1  it can\n"),
		out,
	)
	testing.expect(t, !strings.contains(out, "<rule>"), out)
	testing.expect_value(t, dismissals(Scope{}), "no dismissals in the tree\n")
}

@(test)
names_unknown_reads_the_tree :: proc(t: ^testing.T) {
	if !frontend.installed(.Go) {
		testing.fail_now(t, "review-go is not on the path")
	}
	root, made := new_repo(t)
	testing.expect(t, made)
	defer os.remove_all(root)
	testing.expect(
		t,
		write(root, "x.go", "package x\n\nfunc readConfig() {}\n\nfunc parseFlags() {}\n"),
	)
	testing.expect(
		t,
		os.make_directory_all(filepath.join({root, "docs"}, context.temp_allocator) or_else "") ==
		nil,
	)
	testing.expect(t, write(root, "docs/notes.md", "notes\n"))
	testing.expect(t, git(root, "add", "x.go", "docs/notes.md"))
	c, s := staged(t, root)
	Case :: struct {
		message: string,
		fires:   bool,
	}
	for k in ([]Case{{"x: add parseFlags beside readConfig", false}, {"x: add parseConfig()", true}, {"x: add `load_settings` for docs/notes.md", true}, {"x: touch docs/notes.md", false}, {"x: make the reader faster", false}, {"x: see https://example.com/parseConfig", false}}) {
		c.message = k.message
		got := collect(s, check_names_unknown, context.temp_allocator)
		testing.expectf(t, (len(got) == 1) == k.fires, "%q: got %v", k.message, got)
	}
	_ = slice.contains([]int{1}, 1)
}
