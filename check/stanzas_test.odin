package check

import "core:testing"

@(test)
glued_teardown_is_reported :: proc(t: ^testing.T) {
	Case :: struct {
		name, src: string,
		lines:     []int,
		want:      int,
	}
	cases := []Case {
		{"glued to a loop", "package a\nf :: proc() {\n\txs := make([]int, 4)\n\tdefer delete(xs)\n\tfor x in xs {}\n}", {4}, 1},
		{"blank after", "package a\nf :: proc() {\n\txs := make([]int, 4)\n\tdefer delete(xs)\n\n\tfor x in xs {}\n}", {4}, 0},
		{"last in block", "package a\nf :: proc() {\n\txs := make([]int, 4)\n\tdefer delete(xs)\n}", {4}, 0},
		{
			"two resources",
			"package a\nf :: proc() {\n\ta := make([]int, 4)\n\tdefer delete(a)\n\tb := make([]int, 4)\n\tdefer delete(b)\n\n\tuse(a, b)\n}",
			{4, 6},
			0,
		},
		{
			"two resources glued",
			"package a\nf :: proc() {\n\ta := make([]int, 4)\n\tdefer delete(a)\n\tb := make([]int, 4)\n\tdefer delete(b)\n\tuse(a, b)\n}",
			{4, 6},
			1,
		},
		{"defer block", "package a\nf :: proc() {\n\tdefer {\n\t\tclose()\n\t}\n\tuse()\n}", {3}, 1},
		{"defer block spaced", "package a\nf :: proc() {\n\tdefer {\n\t\tclose()\n\t}\n\n\tuse()\n}", {3}, 0},
		{"unchanged defer", "package a\nf :: proc() {\n\tdefer delete(xs)\n\tuse()\n}", {4}, 0},
		{"not a defer", "package a\nf :: proc() {\n\tdeferred := 1\n\tuse()\n}", {3}, 0},
	}
	for c in cases {
		got := collect(temp_scope(c.src, ..c.lines), check_stanza_glued_teardown, context.temp_allocator)
		testing.expectf(t, len(got) == c.want, "%s: got %v, want %d", c.name, got, c.want)
		for f in got {
			testing.expect_value(t, f.rule, "stanza-glued-teardown")
		}
	}
}
