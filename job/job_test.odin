package job

import "core:strings"
import "core:testing"

import "../change"
import "../finding"
import "../txt"

dyn :: proc(items: []$T) -> [dynamic]T {
	out := make([dynamic]T, context.temp_allocator)
	append(&out, ..items)
	return out
}

@(test)
jobs_carry_their_criteria :: proc(t: ^testing.T) {
	jobs := all(context.temp_allocator)
	testing.expect_value(t, len(jobs), 8)
	for j in jobs {
		testing.expectf(t, len(rules(j.criteria)) >= 4, "%s cites too few rules", j.name)
		testing.expect(t, strings.contains(j.criteria, "- `"))
	}
	allowed := rules(jobs[1].criteria)
	testing.expect(t, allowed["cannot-fail"], "the tests criteria name cannot-fail")
	picked, err := chosen("tests, hygiene", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(picked), 2)
	_, err = chosen("nothing", context.temp_allocator)
	testing.expect(t, strings.contains(err, "no job called"))
}

@(test)
subjects_render_the_part_each_job_reads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change {
		message    = "x: do the thing",
		stat       = " a.go | 2 +-",
		convention = {"x: earlier"},
		symbols    = dyn(
			[]change.Symbol {
				{
					name = "Parse",
					kind = "func",
					file = "a.go",
					line = 3,
					exported = true,
					signature = "func Parse() {",
					doc = "Parse reads.\nMore.",
				},
			},
		),
		tests      = dyn(
			[]change.Function {
				{
					name = "TestParse",
					file = "a_test.go",
					line = 9,
					body = "func TestParse(t *testing.T) {\n\tt.Skip()\n\tParse()\n}",
					skips = 10,
				},
			},
		),
		comments   = dyn(
			[]change.Located {
				{text = "one", file = "a.go", line = 1, below = "x := 1"},
				{text = "two", file = "a.go", line = 2, below = "y := 2\nz := 3"},
				{text = "parse the input", file = "a.go", line = 7, below = "func parseInput() {"},
			},
		),
		index      = {
			{
				name = "Parse",
				kind = "func",
				file = "a.go",
				line = 3,
				body = "func Parse() {\n\treturn\n}",
			},
		},
	}
	c.candidates = make(map[string][]string)
	c.candidates["Parse"] = []string{"b.go:4: func parse() {"}
	c.twins = make(map[string][]string)
	c.twins["Parse"] = []string{"b.go:1: const Parse = 1   <- same value"}
	namer := namer_subject(&c, context.temp_allocator)
	for want in ([]string{"a.go:3  func Parse  (exported)", "doc: Parse reads.", "names already in this repository: b.go:4: func parse() {"}) {
		testing.expectf(
			t,
			strings.contains(namer, want),
			"%q missing from namer:\n%s",
			want,
			namer,
		)
	}
	dup := duplication_subject(&c, context.temp_allocator)
	for want in ([]string{"Judge every pair on this list.", "      b.go:1: const Parse = 1\n", "NEW  a.go:3  func Parse", "       b.go:4: func parse() {"}) {
		testing.expectf(
			t,
			strings.contains(dup, want),
			"%q missing from duplication:\n%s",
			want,
			dup,
		)
	}
	tests := tests_subject(&c, context.temp_allocator)
	for want in ([]string{"--- a_test.go:9 TestParse  (skips itself at line 10)", "Functions the tests call", "--- a.go:3 Parse\nfunc Parse() {"}) {
		testing.expectf(
			t,
			strings.contains(tests, want),
			"%q missing from tests:\n%s",
			want,
			tests,
		)
	}
	claims := claims_subject(&c, context.temp_allocator)
	for want in ([]string{"a.go:1  one\na.go:2  two\n    code: y := 2\n    code: z := 3\n"}) {
		testing.expectf(
			t,
			strings.contains(claims, want),
			"%q missing from claims:\n%s",
			want,
			claims,
		)
	}
	testing.expect(
		t,
		!strings.contains(claims, "parse the input"),
		"a restating comment is not a claim",
	)
	hygiene := hygiene_subject(&c, context.temp_allocator)
	for want in ([]string{"Commit message:\n\nx: do the thing", "Files changed:\n a.go | 2 +-", "  x: earlier"}) {
		testing.expectf(
			t,
			strings.contains(hygiene, want),
			"%q missing from hygiene:\n%s",
			want,
			hygiene,
		)
	}
	empty := change.Change{}
	testing.expect_value(t, namer_subject(&empty, context.temp_allocator), "")
	testing.expect_value(t, hygiene_subject(&empty, context.temp_allocator), "")
}

@(test)
answers_are_decoded_and_held_to_the_criteria :: proc(t: ^testing.T) {
	allowed := rules("- `cannot-fail` x\n- `other` y\n", context.temp_allocator)
	raw, found := txt.object(
		"Sure! {\"findings\":[{\"rule\":\"cannot-fail\",\"severity\":\"must-fix\",\"file\":\"a_test.go\",\"line\":4,\"symbol\":\"TestX\",\"message\":\"m\",\"fix\":\"f\"},{\"rule\":\"invented\",\"severity\":\"note\",\"message\":\"n\"}]} thanks",
	)
	testing.expect(t, found)
	got, ok := decode(raw, "tests", allowed, allocator = context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].job, "tests")
		testing.expect_value(t, got[0].rule, "cannot-fail")
		testing.expect_value(t, got[0].line, 4)
		testing.expect_value(t, got[0].severity_name, "must-fix")
	}
	testing.expect(t, readable(`{"findings":[]}`))
	testing.expect(t, !readable("no json here"))
	_, none := txt.object("prose")
	testing.expect(t, !none)
	testing.expect_value(t, len(calls("f(); g.h(x); if (y) {", context.temp_allocator)), 2)
}

@(test)
parts_cut_a_large_subject_by_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change {
		files = {"a.go", "b.go", "c.md", "d.go"},
	}
	c.symbols = make([dynamic]change.Symbol)
	long := strings.repeat("x", 9000)
	for name in ([]string{"a.go", "b.go", "d.go"}) {
		append(
			&c.symbols,
			change.Symbol{name = "S", kind = "func", file = name, line = 1, signature = long},
		)
	}
	j := all(context.temp_allocator)[2]
	pieces := parts(j, &c, context.temp_allocator)
	testing.expect_value(t, len(pieces), 3)
	if len(pieces) == 3 {
		testing.expect_value(t, len(pieces[0].symbols), 1)
		testing.expect_value(t, pieces[0].files[0], "a.go")
		testing.expect_value(t, pieces[2].files[0], "d.go")
	}
	small := change.Change {
		files = {"a.go"},
	}
	small.symbols = make([dynamic]change.Symbol)
	append(
		&small.symbols,
		change.Symbol{name = "S", kind = "func", file = "a.go", line = 1, signature = "short"},
	)
	testing.expect_value(t, len(parts(j, &small, context.temp_allocator)), 1)
	// A file the job reads nothing from is in no part: the tests job
	// reads a test file, the namer does not.
	tests_only := change.Change {
		files = {"a.go", "a_test.go"},
	}
	tests_only.symbols = make([dynamic]change.Symbol)
	append(
		&tests_only.symbols,
		change.Symbol {
			name = "S",
			kind = "func",
			file = "a.go",
			line = 1,
			signature = strings.repeat("x", 17000),
		},
	)
	tests_only.tests = make([dynamic]change.Function)
	append(
		&tests_only.tests,
		change.Function {
			name = "TestS",
			file = "a_test.go",
			line = 1,
			body = strings.repeat("y", 17000),
		},
	)
	namer_pieces := parts(all(context.temp_allocator)[2], &tests_only, context.temp_allocator)
	testing.expect_value(t, len(namer_pieces), 1)
	if len(namer_pieces) == 1 {
		testing.expect_value(t, len(namer_pieces[0].files), 1)
		testing.expect_value(t, namer_pieces[0].files[0], "a.go")
	}
	for piece in namer_pieces {
		testing.expect(
			t,
			strings.trim_space(
				all(context.temp_allocator)[2].subject(piece, context.temp_allocator),
			) !=
			"",
			"an empty part is never asked",
		)
	}
	tests_pieces := parts(all(context.temp_allocator)[1], &tests_only, context.temp_allocator)
	testing.expect_value(t, len(tests_pieces), 1)
	if len(tests_pieces) == 1 {
		testing.expect_value(t, tests_pieces[0].files[0], "a_test.go")
	}
}

@(test)
odin_subject_reads_changed_bodies_and_respects_parts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change {
		files = {"domain/read.odin", "cmd/tool/main.odin", "other.go", "domain/read_test.odin", "domain/deleted.odin"},
		index = {
			{
				name = "read",
				kind = "func",
				file = "domain/read.odin",
				line = 3,
				body = "read :: proc() {\n value := lookup()\n consume(value)\n}",
			},
			{
				name = "unchanged",
				kind = "func",
				file = "domain/read.odin",
				line = 12,
				body = "unchanged :: proc() {}",
			},
			{
				name = "main",
				kind = "func",
				file = "cmd/tool/main.odin",
				line = 2,
				body = "main :: proc() {\n cli.run()\n}",
			},
			{
				name = "deleted_only",
				kind = "func",
				file = "domain/deleted.odin",
				line = 2,
				body = "deleted_only :: proc() {}",
			},
			{name = "other", kind = "func", file = "other.go", line = 1, body = "func other() {}"},
			{
				name = "test",
				kind = "func",
				file = "domain/read_test.odin",
				line = 1,
				body = "test :: proc() {}",
			},
		},
	}
	c.added = make(map[string][dynamic]change.Diff_Line)
	c.added["domain/read.odin"] = dyn([]change.Diff_Line{{line = 4, text = " value := lookup()"}})
	c.added["cmd/tool/main.odin"] = dyn([]change.Diff_Line{{line = 3, text = " cli.run()"}})
	c.added["other.go"] = dyn([]change.Diff_Line{{line = 1, text = "func other() {}"}})
	c.added["domain/read_test.odin"] = dyn(
		[]change.Diff_Line{{line = 1, text = "test :: proc() {}"}},
	)
	c.imports = make(map[string][]string)
	c.imports["domain/read.odin"] = {"core:os"}
	c.packages = make(map[string]string)
	c.packages["domain/read.odin"] = "domain"
	got := odin_subject(&c, context.temp_allocator)
	for want in ([]string{"domain/read.odin:3 read", "package: domain", "import: core:os", "consume(value)", "4:  value := lookup()", "cmd/tool/main.odin:2 main"}) {
		testing.expectf(t, strings.contains(got, want), "missing %q in %s", want, got)
	}
	for absent in ([]string{"unchanged", "other.go", "read_test.odin", "deleted_only"}) {
		testing.expectf(t, !strings.contains(got, absent), "unexpected %q in %s", absent, got)
	}
	piece := part(&c, []string{"cmd/tool/main.odin"}, context.temp_allocator)
	got = odin_subject(piece, context.temp_allocator)
	testing.expect(t, strings.contains(got, "cli.run()"))
	testing.expect(
		t,
		!strings.contains(got, "lookup()"),
		"shared index must not leak bodies from other parts",
	)
	empty := change.Change{}
	testing.expect_value(t, odin_subject(&empty, context.temp_allocator), "")
}

@(test)
stanzas_subject_numbers_bodies_and_marks_added_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change {
		files = {"a.go", "notes.md"},
		index = {
			{name = "f", kind = "func", file = "a.go", line = 3, body = "func f() {\n\tx := 1\n\tuse(x)\n}"},
			{name = "g", kind = "func", file = "a.go", line = 9, body = "func g() {}"},
		},
	}
	c.added = make(map[string][dynamic]change.Diff_Line)
	c.added["a.go"] = dyn([]change.Diff_Line{{line = 5, text = "\tuse(x)"}})
	got := stanzas_subject(&c, context.temp_allocator)
	testing.expect(t, strings.contains(got, "--- a.go:3 f\n"), got)
	testing.expect(t, strings.contains(got, "4  \tx := 1\n5+ \tuse(x)\n"), got)
	testing.expect(t, !strings.contains(got, " g\n"), got)
}

@(test)
a_ceiling_lowers_what_a_job_reports :: proc(t: ^testing.T) {
	allowed := make(map[string]bool, context.temp_allocator)
	allowed["stanza-glued-loop"] = true
	raw := `{"findings":[{"rule":"stanza-glued-loop","severity":"must-fix","file":"a.go","line":3},{"rule":"stanza-glued-loop","severity":"note","file":"a.go","line":9}]}`
	got, ok := decode(raw, "stanzas", allowed, .Consider, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0].severity, finding.Severity.Consider)
	testing.expect_value(t, got[0].severity_name, "consider")
	testing.expect_value(t, got[1].severity, finding.Severity.Note)
}

@(test)
artifact_reader_receives_build_code_and_fixture_content :: proc(t: ^testing.T) {
	c := change.Change {
		files = {"justfile", "golden/redirect", "x.odin.fixture", "fix.patch", "a.go"},
		diff = "diff --git a/justfile b/justfile\n+    false\ndiff --git a/x.odin.fixture b/x.odin.fixture\n+broken :: proc() {\n",
	}
	got := artifacts_subject(&c, context.temp_allocator)
	testing.expect(t, strings.contains(got, "Read artifact: justfile"))
	testing.expect(t, strings.contains(got, "Read artifact: golden/redirect"))
	testing.expect(t, strings.contains(got, "Read artifact: x.odin.fixture"))
	testing.expect(t, strings.contains(got, "Read artifact: fix.patch"))
	testing.expect(t, !strings.contains(got, "Read artifact: a.go"))
	testing.expect(t, strings.contains(got, c.diff), "the source reaches the reader unchanged")
	c.files = {"a.go"}
	testing.expect_value(t, artifacts_subject(&c, context.temp_allocator), "")
}

@(test)
claims_receive_the_test_body_below_a_provenance_comment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change{}
	c.comments = make([dynamic]change.Located)
	append(
		&c.comments,
		change.Located {
			file = "live.integration.test.ts",
			line = 4,
			text = "Production snapshot checked with BigQuery job job-123.",
			below = "Deno.test({\nname: \"coverage\",",
		},
	)
	c.tests = make([dynamic]change.Function)
	body := "Deno.test({\n  name: \"coverage\",\nignore: !enabled,\nasync fn() {\nconst actual = await queryLive();\nassertEquals(actual.hours, 19);\n}\n});"
	append(
		&c.tests,
		change.Function {
			file = "live.integration.test.ts",
			line = 5,
			name = "coverage",
			body = body,
		},
	)
	subject := claims_subject(&c, context.temp_allocator)
	testing.expect(t, strings.contains(subject, "code: assertEquals(actual.hours, 19);"))
	// A neighbouring test is not evidence for an unrelated comment.
	c.comments[0].below = "const unrelated = 1;"
	subject = claims_subject(&c, context.temp_allocator)
	testing.expect(t, !strings.contains(subject, "queryLive"))
}
