package check

import "core:testing"

import "../finding"

@(test)
owning_copy_local_heap :: proc(t: ^testing.T) {
	Case :: struct {
		name, src, marker, only, path: string,
		want:                              int,
	}
	heap := "package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n"
	cases := []Case {
		{"dynamic array", heap, "delete(copy)", "", "", 1},
		{
			"map",
			"package a\n\nf :: proc() {\n\torig := make(map[int]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"named length",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, len = 4, allocator = runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"positive cap",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 0, 8, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"assignment copy",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy: [dynamic]int\n\tcopy = orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"chain",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tmid := orig\n\tcopy := mid\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"copy after first delete",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tagain := copy\n\tdelete(again)\n}\n",
			"delete(again)",
			"",
			"",
			1,
		},
		{
			"third delete is the same allocation",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tthird := copy\n\tdelete(orig)\n\tdelete(copy)\n\tdelete(third)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"len is a read",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tn := len(orig)\n\t_ = n\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"both deletes in one arm",
			"package a\n\nf :: proc(cond: bool) {\n\tif cond {\n\t\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\t\tcopy := orig\n\t\tdelete(orig)\n\t\tdelete(copy)\n\t}\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"loop body",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tfor {\n\t\tdelete(orig)\n\t\tdelete(copy)\n\t\tbreak\n\t}\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"nested procedure",
			"package a\n\nf :: proc() {\n\tg :: proc() {\n\t\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\t\tcopy := orig\n\t\tdelete(orig)\n\t\tdelete(copy)\n\t}\n\t_ = g\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"inline struct element",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]struct { x: int }, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"os heap allocator",
			"package a\n\nimport \"core:os\"\n\nf :: proc() {\n\torig := make([dynamic]int, 4, os.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"runtime import alias",
			"package a\n\nimport rt \"base:runtime\"\n\nf :: proc() {\n\torig := make([dynamic]int, 4, rt.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"specific delete procedure",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete_dynamic_array(orig)\n\tdelete_dynamic_array(copy)\n}\n",
			"delete_dynamic_array(copy)",
			"",
			"",
			1,
		},
		{
			"multi return",
			"package a\n\nf :: proc() {\n\torig, _ := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"delete(copy)",
			"",
			"",
			1,
		},
		{
			"two procedures",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n\ng :: proc() {\n\torig := make(map[int]int, 2, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			2,
		},
		{"only the second delete is added", heap, "delete(copy)", "delete(copy)", "", 1},
		{"unchanged lines", heap, "", "package a", "", 0},
		{"test file", heap, "", "", "a_test.odin", 0},
		{"does not parse", "package a\n\nf :: proc( {\n", "", "", "", 0},
		{
			"no length",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"zero length",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 0, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"map without capacity",
			"package a\n\nf :: proc() {\n\torig := make(map[int]int, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"implicit context allocator",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4)\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"temp allocator",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, context.temp_allocator)\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"slice",
			"package a\n\nf :: proc() {\n\torig := make([]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"named element type",
			"package a\n\nFoo :: struct { x: int }\n\nf :: proc() {\n\torig := make([dynamic]Foo, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"empty struct element",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]struct {}, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"parameter",
			"package a\n\nf :: proc(orig: [dynamic]int) {\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"same variable twice",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tdelete(orig)\n\tdelete(orig)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"header cleared",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\torig = {}\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"exclusive arms",
			"package a\n\nf :: proc(cond: bool) {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tif cond {\n\t\tdelete(orig)\n\t} else {\n\t\tdelete(copy)\n\t}\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"append takes the address",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tappend(&orig, 1)\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"call may free",
			"package a\n\nf :: proc(sink: proc(x: [dynamic]int)) {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tsink(orig)\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"return between deletes",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\treturn\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"distinct allocations",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := make([dynamic]int, 4, runtime.heap_allocator())\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"shadowed make",
			"package a\n\nmake :: proc(x: int) -> int { return x }\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"shadowed delete",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\t{\n\t\tdelete :: proc(x: [dynamic]int) {}\n\t\tdelete(orig)\n\t\tdelete(copy)\n\t}\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"shadowed runtime",
			"package a\n\nf :: proc() {\n\truntime := 1\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n\t_ = runtime\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"import shadows runtime",
			"package a\n\nimport runtime \"core:fmt\"\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"local shadows os",
			"package a\n\nimport \"core:os\"\n\nf :: proc() {\n\tos := 1\n\torig := make([dynamic]int, 4, os.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n\t_ = os\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"nested procedure does not capture",
			"package a\n\nf :: proc() {\n\torig := make([dynamic]int, 4, runtime.heap_allocator())\n\tcopy := orig\n\tg :: proc() {\n\t\tdelete(orig)\n\t\tdelete(copy)\n\t}\n\t_ = g\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"fixed capacity",
			"package a\n\nf :: proc() {\n\torig := make([dynamic; 4]int, runtime.heap_allocator())\n\tcopy := orig\n\tdelete(orig)\n\tdelete(copy)\n}\n",
			"",
			"",
			"",
			0,
		},
	}
	for c in cases {
		path := c.path
		if path == "" {
			path = "a.odin"
		}
		lines: []int
		if c.only != "" {
			lines = []int{source_line(c.src, c.only)}
		} else {
			lines = source_every_line(c.src)
		}
		got := collect(scope_from_source(path, c.src, lines), check_owning_copy, context.temp_allocator)
		testing.expectf(t, len(got) == c.want, "%s: got %v, want %d", c.name, got, c.want)
		for item in got {
			testing.expect_value(t, item.rule, "odin-owning-copy")
			testing.expect_value(t, item.severity, finding.Severity.Must_Fix)
		}
		if c.want == 1 && c.marker != "" && len(got) == 1 {
			testing.expectf(
				t,
				got[0].line == source_line(c.src, c.marker),
				"%s: line %d, want %d",
				c.name,
				got[0].line,
				source_line(c.src, c.marker),
			)
		}
	}
}
