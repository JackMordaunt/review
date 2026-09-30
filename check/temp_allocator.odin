package check

// The temp allocator is an arena (base:runtime's
// default_temporary_allocator.odin) given back whole by free_all or a
// guard, not piece by piece, so neither the tracking allocator nor a
// leak check sees it grow. A loop that takes from it every iteration and
// never gives back grows without bound all the same, and only reading
// the loop shows it. The file is parsed here with Odin's own parser
// rather than by the sidecar, which reports declarations and not what
// their bodies call.

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"

import "../finding"

// temp_printers are the fmt procedures that allocate from the temp
// allocator without being passed it.
@(private = "file")
temp_printers := []string {
	"tprint",
	"tprintln",
	"tprintf",
	"tprintfln",
	"ctprint",
	"ctprintf",
	"ctprintfln",
}

// temp_resetters are the calls that give the temp allocator back: the
// guards, which end with the scope they open, and the explicit begin.
// free_all is one only when it is handed the temp allocator.
@(private = "file")
temp_resetters := []string {
	"TEMP_ALLOCATOR_TEMP_GUARD",
	"DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD",
	"temp_allocator_temp_begin",
	"default_temp_allocator_temp_begin",
}

// Span is the stretch of a file one node covers, by byte offset.
@(private = "file")
Span :: struct {
	start, end: int,
}

// Temp_Sites is what one file's walk collects: the bodies of its loops
// and procedure literals, the calls that take from the temp allocator,
// and the ones that give back.
@(private = "file")
Temp_Sites :: struct {
	src:    string,
	loops:  [dynamic]Span,
	procs:  [dynamic]Span,
	takes:  [dynamic]Temp_Take,
	resets: [dynamic]int,
}

// Temp_Take is one allocation from the temp allocator: where, on which
// line, and what the message calls it.
@(private = "file")
Temp_Take :: struct {
	offset: int,
	line:   int,
	what:   string,
}

// check_temp_in_loop reports an allocation from the temp allocator, on a
// line the change adds, inside a loop that never resets it. A loop is
// reset when anything in its body, at any depth, is a guard, a begin, or
// free_all of the temp allocator; any enclosing loop's reset bounds the
// growth to one of its iterations. Calls are not followed into other
// procedures, so a reset or an allocation hidden in a callee is not seen.
check_temp_in_loop :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	added := make(map[int]bool, context.temp_allocator)
	for file in sorted_keys(s.c.added) {
		if !strings.has_suffix(file, ".odin") || is_test_file(file) {
			continue
		}
		src, ok := s.sources[file]
		if !ok {
			continue
		}
		clear(&added)
		for l in s.c.added[file] {
			added[l.line] = true
		}
		for take in temp_takes_in_loops(file, string(src)) {
			if !added[take.line] {
				continue
			}
			append(
				out,
				static(
					"odin-temp-in-loop",
					.Consider,
					fmt.aprintf(
						"`%s` takes from the temp allocator on every iteration of this loop and nothing resets it; the arena grows until the loop ends, and no leak check will say so",
						take.what,
					),
					"add `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` at the top of the loop body, or free_all(context.temp_allocator) at its end",
					file = file,
					line = take.line,
				),
			)
		}
	}
}

// temp_takes_in_loops is every temp allocation in a file that some loop
// repeats and no enclosing loop resets, one per line, in order. A file
// that does not parse gives none; odin check says why.
@(private = "file")
temp_takes_in_loops :: proc(path, src: string) -> []Temp_Take {
	context.allocator = context.temp_allocator
	file := new(ast.File)
	file.fullpath = path
	file.src = src
	p := parser.default_parser()
	p.err = nil
	p.warn = nil
	if !parser.parse_file(&p, file) {
		return nil
	}
	w := Temp_Sites {
		src = src,
	}
	v := ast.Visitor {
		visit = temp_visit,
		data  = &w,
	}
	for decl in file.decls {
		ast.walk(&v, decl)
	}
	out := make([dynamic]Temp_Take)
	last := 0
	for take in w.takes {
		if take.line == last {
			continue
		}
		repeated, reset := false, false
		home := innermost(w.procs[:], take.offset)
		for loop in w.loops {
			if !within(loop, take.offset) || innermost(w.procs[:], loop.start) != home {
				continue
			}
			repeated = true
			for r in w.resets {
				if within(loop, r) && innermost(w.procs[:], r) == home {
					reset = true
				}
			}
		}
		if repeated && !reset {
			append(&out, take)
			last = take.line
		}
	}
	return out[:]
}

// temp_visit records the nodes the rule reads as the walk meets them.
@(private = "file")
temp_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	w := (^Temp_Sites)(v.data)
	#partial switch n in node.derived {
	case ^ast.For_Stmt:
		append(&w.loops, span_of(n.body))
	case ^ast.Range_Stmt:
		append(&w.loops, span_of(n.body))
	case ^ast.Proc_Lit:
		if n.body != nil {
			append(&w.procs, span_of(n.body))
		}
	case ^ast.Assign_Stmt:
		// context.allocator = context.temp_allocator hands the temp
		// allocator to every call after it; the assignment is the site.
		for lhs, i in n.lhs {
			if i < len(n.rhs) &&
			   text_of(w.src, lhs) == "context.allocator" &&
			   is_temp(w.src, n.rhs[i]) {
				append(
					&w.takes,
					Temp_Take {
						n.pos.offset,
						n.pos.line,
						"context.allocator = context.temp_allocator",
					},
				)
			}
		}
	case ^ast.Call_Expr:
		name := callee_name(n.expr)
		callee := text_of(w.src, n.expr)
		passes := false
		for arg in n.args {
			value := arg
			if field, ok := arg.derived_expr.(^ast.Field_Value); ok {
				value = field.value
			}
			passes ||= is_temp(w.src, value)
		}
		// Handing memory back to the temp allocator is not taking it.
		switch {
		case slice.contains(temp_resetters, name) || (name == "free_all" && passes):
			append(&w.resets, n.pos.offset)
		case name == "free" || name == "delete":
		case passes || (slice.contains(temp_printers, name) && callee != name):
			append(&w.takes, Temp_Take{n.pos.offset, n.pos.line, callee})
		}
	}
	return v
}

// callee_name is the name a call is made by, without its package.
@(private = "file")
callee_name :: proc(e: ^ast.Expr) -> string {
	#partial switch x in e.derived_expr {
	case ^ast.Ident:
		return x.name
	case ^ast.Selector_Expr:
		if x.field != nil {
			return x.field.name
		}
	}
	return ""
}

// is_temp reports an expression that is context.temp_allocator.
@(private = "file")
is_temp :: proc(src: string, e: ^ast.Expr) -> bool {
	return e != nil && text_of(src, e) == "context.temp_allocator"
}

@(private = "file")
text_of :: proc(src: string, n: ^ast.Node) -> string {
	if n == nil || n.pos.offset < 0 || n.end.offset > len(src) || n.pos.offset > n.end.offset {
		return ""
	}
	return strings.trim_space(src[n.pos.offset:n.end.offset])
}

@(private = "file")
span_of :: proc(n: ^ast.Node) -> Span {
	return {n.pos.offset, n.end.offset}
}

@(private = "file")
within :: proc(s: Span, offset: int) -> bool {
	return s.start <= offset && offset < s.end
}

// innermost is the start of the smallest procedure body holding an
// offset, or -1 at file scope: a loop outside the procedure an
// allocation sits in does not repeat it.
@(private = "file")
innermost :: proc(procs: []Span, offset: int) -> int {
	// Bodies nest rather than overlap, so the innermost starts last.
	start := -1
	for p in procs {
		if within(p, offset) && p.start > start {
			start = p.start
		}
	}
	return start
}
