package check

import "base:runtime"
import "core:strings"
import "core:testing"

import "../finding"

@(test)
partial_construction_failure_return :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		src:    string,
		lines:  []int,
		want:   int,
		symbol: string,
		path:   string,
	}
	TAIL :: "\nstep :: proc() -> bool { return false }\nstep2 :: proc() -> (int, bool) { return 0, false }\n"
	cases := []Case {
		{
			name = "or_return abandons new",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "defer free",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tdefer free(p)\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "free on the failure arm",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\tfree(p)\n\t\treturn false\n\t}\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "named result is returned",
			src = "package a\nbuild :: proc() -> (p: ^int, ok: bool) {\n\tp = new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "shadowed named result",
			src = "package a\nbuild :: proc() -> (p: ^int, ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "context allocator",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int)\n\t_ = step() or_return\n\treturn p != nil\n}\n" + TAIL,
			want = 0,
		},
		{
			name = "temp allocator",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, context.temp_allocator)\n\t_ = step() or_return\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "file shadows new",
			src = "package a\nnew :: proc(x: int) -> ^int { return nil }\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "local shadows new",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tnew := proc(T: typeid, allocator: runtime.Allocator) -> ^int { return nil }\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\t_ = new\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "local shadows runtime",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\truntime := 1\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\t_ = runtime\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "os heap allocator",
			src = "package a\nimport \"core:os\"\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, os.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "import alias",
			src = "package a\nimport rt \"base:runtime\"\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, rt.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "wrong os import",
			src = "package a\nimport os \"core:fmt\"\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, os.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "zero slice",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make([]int, 0, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn len(p) == 0\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "slice make",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make([]int, 4, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn len(p) == 4\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "dynamic without cap",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make([dynamic]int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "dynamic with cap",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make([dynamic]int, 4, runtime.heap_allocator())\n\tappend(&p, 1)\n\t_ = step() or_return // #fail\n\treturn true\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "map without cap",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make(map[int]int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "map with cap",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make(map[int]int, 4, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn true\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "struct copy still owned",
			src = "package a\nThing :: struct { p: ^int }\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tt := Thing{p}\n\t_ = step() or_return // #fail\n\treturn t.p != nil\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "checked failure",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\treturn false // #fail\n\t}\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "parameter is not a later step",
			src = "package a\nbuild :: proc(ok: bool) -> bool {\n\tp := new(int, runtime.heap_allocator())\n\tif !ok {\n\t\treturn false\n\t}\n\treturn p != nil\n}\n",
			want = 0,
		},
		{
			name = "cleanup helper",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\tdestroy_node(p)\n\t\treturn false\n\t}\n\treturn p != nil\n}\ndestroy_node :: proc(p: ^int) { free(p) }\n" +
			TAIL,
			want = 0,
		},
		{
			name = "unknown call",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\tlog(p)\n\t\treturn false\n\t}\n\treturn p != nil\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "success only",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\treturn p != nil\n}\n",
			want = 0,
		},
		{
			name = "or_return is the allocation",
			src = "package a\nimport \"base:runtime\"\nbuild :: proc() -> runtime.Allocator_Error {\n\tp := new(int, runtime.heap_allocator()) or_return\n\tfree(p)\n\treturn nil\n}\n",
			want = 0,
		},
		{
			name = "empty struct",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(struct {}, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" + TAIL,
			want = 0,
		},
		{
			name = "same file struct",
			src = "package a\nNode :: struct { x: int }\nbuild :: proc() -> (ok: bool) {\n\tp := new(Node, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "unknown named type",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(Unknown, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" + TAIL,
			want = 0,
		},
		{
			name = "write through parameter",
			src = "package a\nbuild :: proc(out: ^^int) -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tout^ = p\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "delete make",
			src = "package a\nbuild :: proc() -> bool {\n\tp := make([]int, 4, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\tdelete(p)\n\t\treturn false\n\t}\n\treturn len(p) == 4\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "len does not consume",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := make([]int, 4, runtime.heap_allocator())\n\tn := len(p)\n\t_ = step() or_return // #fail\n\t_ = n\n\treturn true\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "nested procedure is separate",
			src = "package a\nbuild :: proc() {\n\tp := new(int, runtime.heap_allocator())\n\tg := proc() -> (ok: bool) {\n\t\t_ = step() or_return\n\t\treturn true\n\t}\n\t_ = p\n\t_ = g\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "nested procedure leaks",
			src = "package a\nbuild :: proc() {\n\tg := proc() -> (ok: bool) {\n\t\tp := new(int, runtime.heap_allocator())\n\t\t_ = step() or_return // #fail\n\t\treturn p != nil\n\t}\n\t_ = g\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "capture silences",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tg := proc() { free(p) }\n\t_ = g\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "block defer runs on exit",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t{\n\t\tdefer free(p)\n\t}\n\t_ = step() or_return\n\treturn true\n}\n" +
			TAIL,
			want = 0,
		},
		{
			name = "two allocations one freed",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tq := new(int, runtime.heap_allocator())\n\tdefer free(q)\n\t_ = step() or_return // #fail\n\treturn p != nil && q != nil\n}\n" +
			TAIL,
			want = 1,
			symbol = "p",
		},
		{
			name = "both allocations",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tq := new(int, runtime.heap_allocator())\n\t_ = step() or_return // #fail\n\treturn p != nil && q != nil\n}\n" +
			TAIL,
			want = 2,
		},
		{
			name = "failure returns the pointer",
			src = "package a\nbuild :: proc() -> ^int {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif !ok {\n\t\treturn p\n\t}\n\treturn p\n}\n" + TAIL,
			want = 0,
		},
		{
			name = "own error is not a later step",
			src = "package a\nbuild :: proc() -> bool {\n\tp, err := new(int, runtime.heap_allocator())\n\tif err != nil {\n\t\treturn false\n\t}\n\treturn p != nil\n}\n",
			want = 0,
		},
		{
			name = "later or_return after own error check",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp, err := new(int, runtime.heap_allocator())\n\tif err != nil {\n\t\treturn false\n\t}\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "nil error from a later call",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, err := step2()\n\tif err != nil {\n\t\treturn false // #fail\n\t}\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "false comparison",
			src = "package a\nbuild :: proc() -> bool {\n\tp := new(int, runtime.heap_allocator())\n\t_, ok := step2()\n\tif ok == false {\n\t\treturn false // #fail\n\t}\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "loop does not hide",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\tfor in 0 ..< 1 {\n\t\tx := 1\n\t\t_ = x\n\t}\n\t_ = step() or_return // #fail\n\treturn p != nil\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "or_return inside a loop",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tfor in 0 ..< 1 {\n\t\tp := new(int, runtime.heap_allocator())\n\t\t_ = step() or_return // #fail\n\t\t_ = p\n\t}\n\treturn true\n}\n" +
			TAIL,
			want = 1,
		},
		{
			name = "unchanged failure",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" + TAIL,
			lines = []int{1},
			want = 0,
		},
		{
			name = "only the allocation is new",
			src = "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator()) // #fail\n\t_ = step() or_return\n\treturn p != nil\n}\n" +
			TAIL,
			lines = nil,
			want = 1,
		},
	}
	for &c in cases {
		if c.path == "" {
			c.path = "a.odin"
		}
		lines := c.lines
		if lines == nil {
			lines = source_every_line(c.src)
		}
		if c.name == "only the allocation is new" {
			lines = []int{source_line(c.src, "#fail")}
		}
		got := collect(
			scope_from_source(c.path, c.src, lines),
			check_partial_construction,
			context.temp_allocator,
		)
		testing.expectf(t, len(got) == c.want, "%s: got %v, want %d", c.name, got, c.want)
		marked := source_line(c.src, "#fail")
		for f in got {
			testing.expect_value(t, f.rule, "odin-partial-construction")
			testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
			if marked != 0 {
				testing.expectf(t, f.line == marked, "%s: line %d, want %d", c.name, f.line, marked)
			}
			if c.symbol != "" {
				testing.expect_value(t, f.symbol, c.symbol)
			}
		}
	}

	skipped := "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\n" +
		TAIL
	got := collect(
		scope_from_source("a_test.odin", skipped, source_every_line(skipped)),
		check_partial_construction,
		context.temp_allocator,
	)
	testing.expectf(t, len(got) == 0, "test file: got %v", got)
}

@(private = "file")
Partial_Scratch :: struct {
	backing: runtime.Allocator,
	live:    [dynamic][]byte,
}

@(private = "file")
partial_construction_scratch_note :: proc(s: ^Partial_Scratch, block: []byte) {
	if len(block) == 0 {
		return
	}
	append(&s.live, block)
}

@(private = "file")
partial_construction_scratch_drop :: proc(s: ^Partial_Scratch, memory: rawptr) {
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
partial_construction_scratch_proc :: proc(
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
	s := (^Partial_Scratch)(allocator_data)
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
		partial_construction_scratch_note(s, block)
		return block, nil
	case .Free:
		partial_construction_scratch_drop(s, old_memory)
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
		partial_construction_scratch_drop(s, old_memory)
		partial_construction_scratch_note(s, block)
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

// The finding string has to outlive the check's scratch allocator. free_all
// on that allocator fills every scratch block with Q. A message allocated
// there no longer contains the failure text.
@(test)
partial_construction_message_outlives_scratch :: proc(t: ^testing.T) {
	caller := context.allocator
	prev_temp := context.temp_allocator
	scratch := new(Partial_Scratch)
	scratch.backing = caller
	scratch.live = make([dynamic][]byte)
	context.temp_allocator = runtime.Allocator {
		procedure = partial_construction_scratch_proc,
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

	src := "package a\nbuild :: proc() -> (ok: bool) {\n\tp := new(int, runtime.heap_allocator())\n\t_ = step() or_return\n\treturn p != nil\n}\nstep :: proc() -> bool { return false }\n"
	scope := scope_from_source("a.odin", src, source_every_line(src))
	out := make([dynamic]finding.Finding)
	check_partial_construction(scope, &out)
	restored :=
		context.allocator.procedure == caller.procedure && context.allocator.data == caller.data
	context.allocator = caller
	free_all(context.temp_allocator)

	testing.expect(t, restored)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 {
		testing.expect(t, strings.contains(out[0].message, "leaves it behind"))
		testing.expect_value(t, out[0].symbol, "p")
		delete(out[0].message)
	}
	delete(out)
}
