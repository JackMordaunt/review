package check

import "core:strings"
import "core:testing"

import "../change"
import "../finding"

// temp_scope is a change adding the given lines, by number, to one Odin
// file whose whole text is src.
temp_scope :: proc(src: string, lines: ..int) -> Scope {
	c := new(change.Change, context.temp_allocator)
	c.added = make(map[string][dynamic]change.Diff_Line, context.temp_allocator)
	text := strings.split(src, "\n", context.temp_allocator)
	added := make([dynamic]change.Diff_Line, context.temp_allocator)
	for n in lines {
		append(&added, change.Diff_Line{n, text[n - 1]})
	}
	c.added["a.odin"] = added
	sources := make(map[string][]byte, context.temp_allocator)
	sources["a.odin"] = transmute([]byte)src
	return Scope{c = c, sources = sources}
}

@(test)
temp_in_loop_is_reported :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		src:   string,
		lines: []int,
		fires: []int,
	}
	cases := []Case {
		{
			"tprintf in a loop",
			"package a\n\nimport \"core:fmt\"\n\nf :: proc() {\n\tfor i in 0 ..< 10 {\n\t\t_ = fmt.tprintf(\"%d\", i)\n\t}\n}\n",
			{7},
			{7},
		},
		{
			"a guard in the body",
			"package a\n\nimport \"base:runtime\"\nimport \"core:fmt\"\n\nf :: proc() {\n\tfor i in 0 ..< 10 {\n\t\truntime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()\n\t\t_ = fmt.tprintf(\"%d\", i)\n\t}\n}\n",
			{8, 9},
			{},
		},
		{
			"free_all at the loop's end",
			"package a\n\nimport \"core:fmt\"\n\nf :: proc() {\n\tfor i in 0 ..< 10 {\n\t\t_ = fmt.tprintf(\"%d\", i)\n\t\tfree_all(context.temp_allocator)\n\t}\n}\n",
			{7, 8},
			{},
		},
		{
			"outside any loop",
			"package a\n\nimport \"core:fmt\"\n\nf :: proc() {\n\t_ = fmt.tprintf(\"%d\", 1)\n\tfor i in 0 ..< 10 {\n\t\t_ = i\n\t}\n}\n",
			{6},
			{},
		},
		{
			"handed it in a nested loop",
			"package a\n\nimport \"core:strings\"\n\nf :: proc(xs: []string) {\n\tfor {\n\t\tfor x in xs {\n\t\t\t_ = strings.clone(x, allocator = context.temp_allocator)\n\t\t}\n\t}\n}\n",
			{8},
			{8},
		},
		{
			"an untouched line",
			"package a\n\nimport \"core:fmt\"\n\nf :: proc() {\n\tfor i in 0 ..< 10 {\n\t\t_ = fmt.tprintf(\"%d\", i)\n\t\t_ = i\n\t}\n}\n",
			{8},
			{},
		},
		{
			"a procedure literal in the loop",
			"package a\n\nimport \"core:fmt\"\n\nf :: proc() {\n\tfor i in 0 ..< 10 {\n\t\tg := proc() -> string {\n\t\t\treturn fmt.tprint(1)\n\t\t}\n\t\t_ = g\n\t}\n}\n",
			{8},
			{},
		},
		{
			"the allocator set in the loop",
			"package a\n\nf :: proc() {\n\tfor {\n\t\tcontext.allocator = context.temp_allocator\n\t\t_ = make([]int, 8)\n\t}\n}\n",
			{5, 6},
			{5},
		},
	}
	for k in cases {
		got := collect(temp_scope(k.src, ..k.lines), check_temp_in_loop, context.temp_allocator)
		testing.expectf(t, len(got) == len(k.fires), "%s: got %v", k.name, got)
		for f, i in got {
			if i < len(k.fires) {
				testing.expectf(
					t,
					f.line == k.fires[i],
					"%s: line %d, want %d",
					k.name,
					f.line,
					k.fires[i],
				)
			}
			testing.expect_value(t, f.rule, "odin-temp-in-loop")
			testing.expect_value(t, f.severity, finding.Severity.Consider)
		}
	}
}
