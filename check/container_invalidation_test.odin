package check

import "base:runtime"
import "core:strings"
import "core:testing"

import "../finding"

@(private = "file")
Container_Invalidation_Scratch :: struct {
	backing: runtime.Allocator,
	live:    [dynamic][]byte,
}

@(private = "file")
container_invalidation_scratch_note :: proc(s: ^Container_Invalidation_Scratch, block: []byte) {
	if len(block) == 0 {
		return
	}
	append(&s.live, block)
}

@(private = "file")
container_invalidation_scratch_drop :: proc(s: ^Container_Invalidation_Scratch, memory: rawptr) {
	if memory == nil {
		return
	}
	for block, i in s.live {
		if raw_data(block) == memory {
			ordered_remove(&s.live, i)
			return
		}
	}
}

@(private = "file")
container_invalidation_scratch_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	result: []byte,
	err: runtime.Allocator_Error,
) {
	s := (^Container_Invalidation_Scratch)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		block := s.backing.procedure(
			s.backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		) or_return
		container_invalidation_scratch_note(s, block)
		return block, nil
	case .Free:
		container_invalidation_scratch_drop(s, old_memory)
		return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
	case .Free_All:
		for block in s.live {
			for i in 0 ..< len(block) {
				block[i] = 'Q'
			}
		}
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		block := s.backing.procedure(
			s.backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		) or_return
		container_invalidation_scratch_drop(s, old_memory)
		container_invalidation_scratch_note(s, block)
		return block, nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {
				.Alloc,
				.Alloc_Non_Zeroed,
				.Free,
				.Free_All,
				.Resize,
				.Resize_Non_Zeroed,
				.Query_Features,
			}
		}
		return nil, nil
	}
	return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
container_invalidation_reports :: proc(t: ^testing.T) {
	Case :: struct {
		name, src, marker, only, path: string,
		want:                              int,
	}
	pointer := "package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\tappend(&xs, 2)\n\t_ = p^\n}\n"
	cases := []Case {
		{"pointer after append", pointer, "_ = p^", "", "", 1},
		{"inferred parameter type", "package a\nf :: proc(unused := 0) {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nappend(&xs, 2)\n_ = p^\n}\n", "_ = p^", "", "", 1},
		{
			"slice after append",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\ts := xs[:]\n\tappend(&xs, 2)\n\t_ = s[0]\n}\n",
			"_ = s[0]",
			"",
			"",
			1,
		},
		{
			"pointer after reserve",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\treserve(&xs, 8)\n\t_ = p^\n}\n",
			"_ = p^",
			"",
			"",
			1,
		},
		{
			"enough capacity",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 4)\n\tp := &xs[0]\n\tappend(&xs, 2)\n\t_ = p^\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"reserve within capacity",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 8)\n\tp := &xs[0]\n\treserve(&xs, 4)\n\t_ = p^\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"reacquired borrow",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\tappend(&xs, 2)\n\tp = &xs[0]\n\t_ = p^\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"dead borrow",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\tappend(&xs, 2)\n\t_ = xs[0]\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"local shadow",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\t{\n\t\tappend :: proc(a: ^[dynamic]int, v: int) {}\n\t\tappend(&xs, 2)\n\t}\n\t_ = p^\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"unknown call",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\thelper(&xs)\n\t_ = p^\n}\n",
			"",
			"",
			"",
			0,
		},
		{
			"bound append failure",
			"package a\n\nf :: proc() {\n\txs := make([dynamic]int, 1, 1)\n\tp := &xs[0]\n\tn, err := append(&xs, 2)\n\tif err != nil {\n\t\t_ = p^\n\t}\n\t_ = n\n}\n",
			"",
			"",
			"",
			0,
		},
		{"bound reserve failure", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nerr := reserve(&xs, 8)\nif err != nil { _ = p^ }\n}\n", "", "", "", 0},
		{"bound resize failure", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nerr := resize(&xs, 8)\nif err != nil { _ = p^ }\n}\n", "", "", "", 0},
		{"helper repairs borrow", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nappend(&xs, 2)\nrepair(&p, &xs)\n_ = p^\n}\n", "", "", "", 0},
		{"pointer alias repairs borrow", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nq := &p\nappend(&xs, 2)\nq^ = &xs[0]\n_ = p^\n}\n", "", "", "", 0},
		{"loop inside capacity", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 8)\np := &xs[0]\nfor i in 0..<3 { append(&xs, i) }\n_ = p^\n}\n", "", "", "", 0},
		{"loop exceeds capacity", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nfor i in 0..<3 { append(&xs, i) }\n_ = p^\n}\n", "_ = p^", "", "", 1},
		{"address before borrow", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np: ^int\nq := &p\np = &xs[0]\nappend(&xs, 2)\nq^ = &xs[0]\n_ = p^\n}\n", "", "", "", 0},
		{"previously addressed borrow repaired", "package a\nf :: proc() {\nxs := make([dynamic]int, 1, 1)\np := &xs[0]\nstash(&p)\np = &xs[0]\nappend(&xs, 2)\nrepair_saved()\n_ = p^\n}\n", "", "", "", 0},
		{"zero-sized elements", "package a\nf :: proc() {\nxs := make([dynamic]struct{}, 1, 1)\np := &xs[0]\nappend(&xs, struct{}{})\n_ = p^\n}\n", "", "", "", 0},
		{"fixed capacity", "package a\nf :: proc() {\nxs: [dynamic; 4]int\nappend(&xs, 1)\np := &xs[0]\nappend(&xs, 2)\n_ = p^\n}\n", "", "", "", 0},
		{"unchanged lines", pointer, "", "package a", "", 0},
		{"test file", pointer, "", "", "a_test.odin", 0},
		{"does not parse", "package a\n\nf :: proc( {\n", "", "", "", 0},
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
		if c.name != "does not parse" {
			testing.expectf(t, parse_odin_source(path, c.src) != nil, "%s: fixture must parse", c.name)
		}
		got := collect(
			scope_from_source(path, c.src, lines),
			check_container_invalidation,
			context.temp_allocator,
		)
		testing.expectf(t, len(got) == c.want, "%s: got %v, want %d", c.name, got, c.want)
		for item in got {
			testing.expect_value(t, item.rule, "odin-container-invalidation")
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

	caller := context.allocator
	prev_temp := context.temp_allocator
	scratch := new(Container_Invalidation_Scratch)
	scratch.backing = caller
	scratch.live = make([dynamic][]byte)
	context.allocator = caller
	context.temp_allocator = runtime.Allocator {
		procedure = container_invalidation_scratch_proc,
		data      = scratch,
	}
	defer {
		context.allocator = caller
		context.temp_allocator = prev_temp
		for block in scratch.live {
			free(raw_data(block))
		}
		delete(scratch.live)
		free(scratch)
	}
	scope := scope_from_source(
		"a.odin",
		pointer,
		source_every_line(pointer),
	)
	out := make([dynamic]finding.Finding)
	check_container_invalidation(scope, &out)
	free_all(context.temp_allocator)
	context.allocator = caller
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 {
		testing.expect(t, strings.contains(out[0].message, "points into"))
		delete(out[0].message)
	}
	delete(out)
}
