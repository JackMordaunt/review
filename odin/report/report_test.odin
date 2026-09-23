package report

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../change"
import "../finding"

@(test)
render_groups_by_severity :: proc(t: ^testing.T) {
	out := render(
		Contract {
			findings = {
				{
					job = "tests",
					rule = "cannot-fail",
					severity = .Must_Fix,
					file = "a_test.go",
					line = 4,
					message = "one",
				},
				{
					job = "namer",
					rule = "abbreviation",
					severity = .Note,
					symbol = "cfg",
					message = "two",
				},
			},
			dismissed = {{}, {}},
		},
		allocator = context.temp_allocator,
	)
	for want in ([]string{"MUST-FIX", "NOTE", "one", "two", "2 findings", "2 dismissed in the source"}) {
		testing.expectf(t, strings.contains(out, want), "%q missing from:\n%s", want, out)
	}
	testing.expect_value(t, strings.count(out, "MUST-FIX"), 1)
}

@(test)
render_nothing :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		strings.trim_space(render(Contract{}, allocator = context.temp_allocator)),
		"no findings",
	)
	out := render(
		Contract{dismissed = {{}, {}, {}}, retracted = {{}}},
		allocator = context.temp_allocator,
	)
	testing.expect(t, strings.contains(out, "3 dismissed in the source"))
	testing.expect(
		t,
		strings.contains(out, "1 of the findings reported did not survive verification"),
	)
	out = render(
		Contract{baseline = Baseline{from = "old.json", persisting = {"abc"}}},
		allocator = context.temp_allocator,
	)
	testing.expect(t, strings.contains(out, "against old.json: 0 resolved, 1 persisting, 0 new"))
	testing.expect(t, strings.contains(out, "persisting: abc"))
}

@(test)
encode_carries_the_contract :: proc(t: ^testing.T) {
	out, ok := encode(
		Contract {
			status = "incomplete",
			provider = "api/probe",
			findings = {
				{
					job = "static",
					rule = "test-deleted",
					severity = .Must_Fix,
					file = "x_test.go",
					line = 3,
					message = "m",
					verified = true,
				},
			},
			retracted = {
				{
					finding = {
						job = "tests",
						rule = "cannot-fail",
						severity = .Must_Fix,
						file = "x_test.go",
						message = "m",
					},
					reason = "the test can fail",
				},
			},
			failed = {{job = "duplication", error = "context canceled"}},
			skipped = {"hygiene"},
			uncovered = {{file = "a.odin", reason = "no tests parser"}},
			dismissed = {{finding = {rule = "cannot-fail"}, why = "wrong"}},
			truncated = true,
			usage = {tokens_in = 10, tokens_out = 2, cached = 1, replayed = 3, cost = 0.5},
		},
		context.temp_allocator,
	)
	testing.expect(t, ok, "encode")
	for want in ([]string{`"version": 1`, `"status": "incomplete"`, `"provider": "api/probe"`, `"severity": "must-fix"`, `"verified": true`, `"id": "`, `"reason": "the test can fail"`, `"error": "context canceled"`, `"skipped": [`, `"a.odin"`, `"why": "wrong"`, `"truncated": true`, `"usd": 0.5`}) {
		testing.expectf(t, strings.contains(out, want), "%s missing from:\n%s", want, out)
	}
	testing.expect(t, !strings.contains(out, `"baseline"`), "an absent baseline is left out")
	testing.expect(t, !strings.contains(out, `"part"`), "part is the reading's own")

	// Every list is present even when empty, and the JSON parses.
	empty, empty_ok := encode(Contract{status = "complete"}, context.temp_allocator)
	testing.expect(t, empty_ok)
	for key in ([]string{"findings", "retracted", "failed", "skipped", "uncovered", "dismissed"}) {
		testing.expectf(t, strings.contains(empty, key), "%s missing from:\n%s", key, empty)
	}
	parsed, parse_err := json.parse_string(empty, allocator = context.temp_allocator)
	testing.expect(t, parse_err == nil, "the JSON parses")
	root := parsed.(json.Object)
	testing.expect_value(t, len(root["findings"].(json.Array)), 0)
	testing.expect(t, !strings.contains(empty, "null"), "no list is null")
	testing.expect(t, strings.contains(empty, `"findings": []`), "an empty list is one line")
	testing.expect(
		t,
		!strings.contains(empty, `"truncated"`),
		"a truncation that did not happen is left out",
	)
	testing.expect(t, strings.contains(out, `"truncated": true`))
}

@(test)
filter_drops_what_the_source_dismisses :: proc(t: ^testing.T) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root, err := os.make_directory_temp(temp, "review-report-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	path := filepath.join({root, "x.go"}, context.temp_allocator) or_else ""
	testing.expect(
		t,
		os.write_entire_file(
			path,
			transmute([]byte)string(
				"package x\n\n//review:" +
				"ignore restates-a-fact the ico package owns it\nconst b = 6\n",
			),
		) ==
		nil,
	)

	kept, dismissed := filter(
		root,
		{
			{file = "x.go", line = 4, rule = "restates-a-fact", message = "dismissed"},
			{file = "x.go", line = 4, rule = "already-named", message = "kept"},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(dismissed), 1)
	testing.expect_value(t, dismissed[0].why, "the ico package owns it")
	testing.expect_value(t, len(kept), 1)
	testing.expect_value(t, kept[0].message, "kept")
}

@(test)
status_says_where_the_hole_is :: proc(t: ^testing.T) {
	c: change.Change
	c.uncovered = make([dynamic]change.Gap, context.temp_allocator)
	testing.expect_value(t, status_of(c, 0), "complete")
	testing.expect_value(t, status_of(c, 1), "incomplete")
	c.truncated = true
	testing.expect_value(t, status_of(c, 0), "incomplete")
	c.truncated = false
	append(&c.uncovered, change.Gap{"a.zig", "no reader"})
	testing.expect_value(t, status_of(c, 0), "incomplete")
	f := finding.Finding{}
	testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
}
