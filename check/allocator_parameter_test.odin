package check

import "core:testing"

@(test)
allocator_parameter_contract :: proc(t: ^testing.T) {
	Case :: struct {
		name, src: string,
		lines:     []int,
		want:      int,
	}
	cases := []Case {
		{"new", "package a\nf :: proc() {\n _ = new(int)\n}", {3}, 1},
		{"slice", "package a\nf :: proc() {\n _ = make([]int, 4)\n}", {3}, 1},
		{"dynamic", "package a\nf :: proc() {\n _ = make([dynamic]int)\n}", {3}, 1},
		{"map", "package a\nf :: proc() {\n _ = make(map[int]int)\n}", {3}, 1},
		{"opaque make", "package a\nf :: proc() {\n _ = make(Custom)\n}", {3}, 0},
		{
			"shadowed builtin",
			"package a\nnew :: proc(x: int) {}\nf :: proc() {\n new(1)\n}",
			{4},
			0,
		},
		{
			"allocator passed",
			"package a\nf :: proc() {\n clone(allocator = context.temp_allocator)\n}",
			{3},
			1,
		},
		{
			"deallocation uses allocator",
			"package a\nf :: proc() {\n delete(xs, context.allocator)\n}",
			{3},
			1,
		},
		{"allocator read", "package a\nf :: proc() {\n a := context.allocator\n _ = a\n}", {3}, 0},
		{"unrelated name", "package a\nf :: proc(allocator: int) {\n _ = new(int)\n}", {3}, 1},
		{
			"typed parameter",
			"package a\nf :: proc(mem: runtime.Allocator) {\n _ = new(int, mem)\n}",
			{3},
			0,
		},
		{
			"runtime import alias",
			"package a\nimport rt \"base:runtime\"\nf :: proc(mem: rt.Allocator) {\n _ = new(int, mem)\n}",
			{4},
			0,
		},
		{
			"allocator type alias",
			"package a\nA :: runtime.Allocator\nf :: proc(mem: A) {\n _ = new(int, mem)\n}",
			{4},
			0,
		},
		{
			"default allocator",
			"package a\nf :: proc(mem := context.allocator) {\n _ = new(int, mem)\n}",
			{3},
			0,
		},
		{
			"default temp",
			"package a\nf :: proc(mem := context.temp_allocator) {\n _ = new(int, mem)\n}",
			{3},
			0,
		},
		{
			"nested independent",
			"package a\nf :: proc(mem := context.allocator) {\n g := proc() { _ = new(int) }\n _ = g\n}",
			{3},
			1,
		},
		{
			"outer independent",
			"package a\nf :: proc() {\n g := proc(mem := context.allocator) { _ = new(int, mem) }\n _ = g\n}",
			{2, 3},
			0,
		},
		{"default expression", "package a\nf :: proc(p := new(int)) {\n _ = p\n}", {2}, 0},
		{"unchanged allocation", "package a\nf :: proc() {\n _ = new(int)\n _ = 1\n}", {4}, 0},
		{"multiline signature", "package a\nf :: proc(\n x: int,\n) {\n _ = new(int)\n}", {3}, 1},
		{"changed signature", "package a\nf :: proc() {\n _ = new(int)\n}", {2}, 1},
		{"fixed ABI main", "package a\nmain :: proc() {\n _ = new(int)\n}", {3}, 1},
		{"fixed ABI callback", "package a\nf :: proc \"c\" () {\n _ = new(int)\n}", {3}, 1},
		{
			"one per procedure",
			"package a\nf :: proc() {\n _ = new(int)\n _ = make([]int, 4)\n}",
			{3, 4},
			1,
		},
	}
	for c in cases {
		got := collect(
			temp_scope(c.src, ..c.lines),
			check_allocator_parameter,
			context.temp_allocator,
		)
		testing.expectf(t, len(got) == c.want, "%s: got %v, want %d", c.name, got, c.want)
		for f in got {
			testing.expect_value(t, f.rule, "odin-allocator-parameter")
		}
	}
}
