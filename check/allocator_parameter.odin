package check

import "core:odin/ast"
import "core:odin/parser"
import "core:strings"

import "../finding"

// Allocator_Parameter_Walk keeps procedure signatures separate from bodies:
// defaults and nested procedure bodies do not allocate in the enclosing body.
@(private = "file")
Allocator_Parameter_Walk :: struct {
	src:             string,
	procs:           [dynamic]^ast.Proc_Lit,
	calls:           [dynamic]^ast.Call_Expr,
	shadowed:        map[string]bool,
	allocator_types: map[string]bool,
	aliases:         [dynamic]^ast.Value_Decl,
}

check_allocator_parameter :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	context.allocator = context.temp_allocator
	for path in sorted_keys(s.c.added) {
		if !strings.has_suffix(path, ".odin") || is_test_file(path) {
			continue
		}
		src, ok := s.sources[path]
		if !ok {
			continue
		}
		file := new(ast.File)
		file.fullpath, file.src = path, string(src)
		p := parser.default_parser()
		p.err, p.warn = nil, nil
		if !parser.parse_file(&p, file) {
			continue
		}
		w := Allocator_Parameter_Walk {
			src             = string(src),
			shadowed        = make(map[string]bool),
			allocator_types = make(map[string]bool),
		}
		w.allocator_types["runtime.Allocator"] = true
		v := ast.Visitor {
			visit = visit_allocator_parameter,
			data  = &w,
		}
		for decl in file.decls {
			ast.walk(&v, decl)
		}
		// Resolve only direct type aliases, including aliases of aliases.
		for _ in 0 ..< len(w.aliases) {
			for alias in w.aliases {
				if !alias.is_mutable &&
				   len(alias.names) == 1 &&
				   len(alias.values) == 1 &&
				   w.allocator_types[read_allocator_source(w.src, alias.values[0])] {
					w.allocator_types[read_allocator_source(w.src, alias.names[0])] = true
				}
			}
		}
		for proc_lit in w.procs {
			if has_allocator_parameter(w.src, proc_lit.type, w.allocator_types) {
				continue
			}
			line := 0
			for call in w.calls {
				// The nearest procedure literal owns the call, including
				// calls in its defaults (which are excluded below).
				owner: ^ast.Proc_Lit
				for candidate in w.procs {
					if candidate.pos.offset <= call.pos.offset &&
					   call.pos.offset < candidate.end.offset &&
					   (owner == nil || candidate.pos.offset > owner.pos.offset) {
						owner = candidate
					}
				}
				if owner != proc_lit ||
				   call.pos.offset < proc_lit.body.pos.offset ||
				   !call_uses_allocator(w.src, call, w.shadowed) {
					continue
				}
				for added in s.c.added[path] {
					if added.line == call.pos.line {
						line = call.pos.line
					} else if line == 0 &&
					   added.line >= proc_lit.pos.line &&
					   added.line <= proc_lit.type.end.line {
						line = added.line
					}
				}
			}
			if line != 0 {
				append(
					out,
					static(
						"odin-allocator-parameter",
						.Must_Fix,
						"this procedure uses an allocator but its signature exposes no allocator parameter",
						"accept an allocator parameter defaulting to context.allocator or context.temp_allocator and route allocations through it; if the ABI fixes this signature, delegate allocation to an allocator-aware helper",
						file = path,
						line = line,
					),
				)
			}
		}
	}
}

@(private = "file")
visit_allocator_parameter :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	w := (^Allocator_Parameter_Walk)(v.data)
	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		if n.body != nil {
			append(&w.procs, n)
		}
	case ^ast.Import_Decl:
		if strings.trim(n.relpath.text, "\"") == "base:runtime" && n.name.text != "" {
			w.allocator_types[strings.concatenate({n.name.text, ".Allocator"})] = true
		}
	case ^ast.Value_Decl:
		append(&w.aliases, n)
		for name in n.names {
			w.shadowed[read_allocator_source(w.src, name)] = true
		}
	case ^ast.Field:
		for name in n.names {
			w.shadowed[read_allocator_source(w.src, name)] = true
		}
	case ^ast.Call_Expr:
		append(&w.calls, n)
	}
	return v
}

@(private = "file")
has_allocator_parameter :: proc(
	src: string,
	typ: ^ast.Proc_Type,
	allocator_types: map[string]bool,
) -> bool {
	if typ == nil || typ.params == nil {
		return false
	}
	for field in typ.params.list {
		if allocator_types[read_allocator_source(src, field.type)] ||
		   read_allocator_source(src, field.default_value) == "context.allocator" ||
		   read_allocator_source(src, field.default_value) == "context.temp_allocator" {
			return true
		}
	}
	return false
}

@(private = "file")
call_uses_allocator :: proc(
	src: string,
	call: ^ast.Call_Expr,
	shadowed: map[string]bool,
) -> bool {
	name := read_allocator_source(src, call.expr)
	if name == "new" && !shadowed[name] && len(call.args) > 0 {
		return true
	}
	if name == "make" && !shadowed[name] && len(call.args) > 0 {
		#partial switch typ in call.args[0].derived_expr {
		case ^ast.Array_Type:
			return typ.len == nil
		case ^ast.Dynamic_Array_Type, ^ast.Map_Type:
			return true
		}
	}
	for arg in call.args {
		value := arg
		if field, ok := arg.derived_expr.(^ast.Field_Value); ok {
			value = field.value
		}
		if read_allocator_source(src, value) == "context.allocator" ||
		   read_allocator_source(src, value) == "context.temp_allocator" {
			return true
		}
	}
	return false
}

@(private = "file")
read_allocator_source :: proc(src: string, node: ^ast.Node) -> string {
	if node == nil ||
	   node.pos.offset < 0 ||
	   node.end.offset > len(src) ||
	   node.pos.offset > node.end.offset {
		return ""
	}
	return strings.trim_space(src[node.pos.offset:node.end.offset])
}
