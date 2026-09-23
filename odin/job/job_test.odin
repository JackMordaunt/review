package job

import "core:strings"
import "core:testing"

import "../change"
import "../txt"

dyn :: proc(items: []$T) -> [dynamic]T {
	out := make([dynamic]T, context.temp_allocator)
	append(&out, ..items)
	return out
}

@(test)
jobs_carry_their_criteria :: proc(t: ^testing.T) {
	jobs := all(context.temp_allocator)
	testing.expect_value(t, len(jobs), 5)
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
	got, ok := decode(raw, "tests", allowed, context.temp_allocator)
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
	testing.expect(t, !contributes(&c, "c.md"))
}
