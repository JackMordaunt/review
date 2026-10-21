package check

// A slice of a mutable local array, or a string cast from that slice,
// borrows the procedure's stack. Odin's string([]u8) and transmute(string)
// are header transmutes, not copies. The compiler's check_unsafe_return
// only sees a slice or address that is still the return expression, so an
// intermediate local, string(), and a named result compile and dangle.
// This check reports those when the backing local is visible in the same
// procedure. Passing &binding to a call, or storing through a pointer after
// that address was taken, drops the borrowed binding. The checker does not
// decide which pointer is which. Temp memory, destroyed owners, and unknown
// ownership are left to inference.

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "../finding"

@(private = "file")
Borrowed_Escape_Kind :: enum {
	None,
	Stack,
	Borrowed,
}

@(private = "file")
Borrowed_Escape_Binding :: struct {
	kind:      Borrowed_Escape_Kind,
	array:     string,
	byte_elem: bool,
	elem:      ^ast.Expr,
	origin:    int,
	result:    bool,
	as_string: bool,
	frame:     int,
}

@(private = "file")
Borrowed_Escape_Shadow :: struct {
	name: string,
	had:  bool,
	prev: Borrowed_Escape_Binding,
}

@(private = "file")
Borrowed_Escape_Snapshot :: struct {
	had:  bool,
	prev: Borrowed_Escape_Binding,
}

@(private = "file")
Borrowed_Escape_Cond :: struct {
	baseline: int,
	restore:  bool,
	saved:    map[string]Borrowed_Escape_Snapshot,
}

@(private = "file")
Borrowed_Escape_File :: struct {
	path:          string,
	added:         map[int]bool,
	out:           ^[dynamic]finding.Finding,
	alloc:         runtime.Allocator,
	string_shadow: bool,
}

@(private = "file")
Borrowed_Escape_Proc :: struct {
	file:        ^Borrowed_Escape_File,
	bindings:    map[string]Borrowed_Escape_Binding,
	frames:      [dynamic][dynamic]Borrowed_Escape_Shadow,
	conds:       [dynamic]Borrowed_Escape_Cond,
	results:     [dynamic]string,
	addressed:   map[string]bool,
	decl_depth:  int,
	defer_depth: int,
}

// check_borrowed_escape reports a changed return of a slice or aliasing
// string whose bytes are a mutable local fixed array, or a [dynamic; N]T,
// of that same procedure.
check_borrowed_escape :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	alloc := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = alloc

	for path in sorted_keys(s.c.added) {
		if !strings.has_suffix(path, ".odin") || is_test_file(path) {
			continue
		}
		src, ok := s.sources[path]
		if !ok {
			continue
		}
		file := parse_odin_source(path, string(src))
		if file == nil {
			continue
		}
		added := make(map[int]bool)
		for line in s.c.added[path] {
			added[line.line] = true
		}
		state := Borrowed_Escape_File {
			path          = path,
			added         = added,
			out           = out,
			alloc         = alloc,
			string_shadow = borrowed_escape_string_shadow(file),
		}
		base := len(out)
		procs := borrowed_escape_procs(file)
		for lit in procs {
			borrowed_escape_proc(&state, lit)
		}
		if len(out) > base {
			slice.sort_by(out[base:], proc(a, b: finding.Finding) -> bool {
				return a.line < b.line
			})
		}
	}
}

@(private = "file")
borrowed_escape_string_shadow :: proc(file: ^ast.File) -> bool {
	for imp in file.imports {
		if imp.name.text == "string" {
			return true
		}
	}
	for decl in file.decls {
		value, is_value := decl.derived_stmt.(^ast.Value_Decl)
		if !is_value {
			continue
		}
		for name in value.names {
			if borrowed_escape_ident(name) == "string" {
				return true
			}
		}
	}
	return false
}

@(private = "file")
borrowed_escape_procs :: proc(file: ^ast.File) -> [dynamic]^ast.Proc_Lit {
	procs := make([dynamic]^ast.Proc_Lit)
	v := ast.Visitor {
		visit = borrowed_escape_visit,
		data  = &procs,
	}
	for decl in file.decls {
		ast.walk(&v, decl)
	}
	return procs
}

@(private = "file")
borrowed_escape_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		if n.body != nil {
			append((^[dynamic]^ast.Proc_Lit)(v.data), n)
		}
	}
	return v
}

@(private = "file")
borrowed_escape_proc :: proc(file: ^Borrowed_Escape_File, lit: ^ast.Proc_Lit) {
	p := Borrowed_Escape_Proc {
		file     = file,
		bindings  = make(map[string]Borrowed_Escape_Binding),
		results   = make([dynamic]string),
		addressed = make(map[string]bool),
	}
	borrowed_escape_push_decl(&p)
	if lit.type != nil {
		borrowed_escape_bind_fields(&p, lit.type.params, false)
		borrowed_escape_bind_fields(&p, lit.type.results, true)
	}
	borrowed_escape_walk_stmt(&p, lit.body)
	borrowed_escape_pop_decl(&p)
}

@(private = "file")
borrowed_escape_bind_fields :: proc(p: ^Borrowed_Escape_Proc, list: ^ast.Field_List, result: bool) {
	if list == nil {
		return
	}
	for field in list.list {
		for name in field.names {
			id := borrowed_escape_ident(name)
			borrowed_escape_define(p, id, Borrowed_Escape_Binding{result = result})
			if result && id != "" && id != "_" {
				append(&p.results, id)
			}
		}
	}
}

@(private = "file")
borrowed_escape_push_decl :: proc(p: ^Borrowed_Escape_Proc) {
	p.decl_depth += 1
	append(&p.frames, make([dynamic]Borrowed_Escape_Shadow))
}

@(private = "file")
borrowed_escape_pop_decl :: proc(p: ^Borrowed_Escape_Proc) {
	frame := pop(&p.frames)
	p.decl_depth -= 1
	for i := len(frame) - 1; i >= 0; i -= 1 {
		sh := frame[i]
		if sh.had {
			p.bindings[sh.name] = sh.prev
		} else {
			delete_key(&p.bindings, sh.name)
		}
	}
}

@(private = "file")
borrowed_escape_push_cond :: proc(p: ^Borrowed_Escape_Proc, restore: bool) {
	append(
		&p.conds,
		Borrowed_Escape_Cond {
			baseline = p.decl_depth,
			restore  = restore,
			saved    = make(map[string]Borrowed_Escape_Snapshot),
		},
	)
}

@(private = "file")
borrowed_escape_pop_cond :: proc(p: ^Borrowed_Escape_Proc) {
	frame := pop(&p.conds)
	if frame.restore {
		for name, old in frame.saved {
			p.bindings[name] = old.prev
		}
		return
	}
	for name, old in frame.saved {
		cleared := old.prev
		cleared.kind = .None
		cleared.as_string = false
		cleared.byte_elem = false
		cleared.elem = nil
		cleared.array = ""
		p.bindings[name] = cleared
	}
}

@(private = "file")
borrowed_escape_define :: proc(p: ^Borrowed_Escape_Proc, name: string, b: Borrowed_Escape_Binding) {
	if name == "" || name == "_" || len(p.frames) == 0 {
		return
	}
	prev, had := p.bindings[name]
	append(&p.frames[len(p.frames) - 1], Borrowed_Escape_Shadow{name, had, prev})
	binding := b
	binding.frame = p.decl_depth
	p.bindings[name] = binding
}

@(private = "file")
borrowed_escape_assign :: proc(p: ^Borrowed_Escape_Proc, name: string, b: Borrowed_Escape_Binding) {
	if name == "" || name == "_" {
		return
	}
	prev, had := p.bindings[name]
	if !had {
		return
	}
	binding := b
	binding.frame = prev.frame
	binding.result = prev.result
	if len(p.conds) > 0 {
		top := &p.conds[len(p.conds) - 1]
		if prev.frame <= top.baseline {
			if _, saved := top.saved[name]; !saved {
				top.saved[name] = {had = true, prev = prev}
			}
		}
	}
	p.bindings[name] = binding
}

// borrowed_escape_pointer_arg is the binding whose header is &name, after
// parentheses, named arguments, and casts. &name[i] is the element, not the
// header, and returns "".
@(private = "file")
borrowed_escape_pointer_arg :: proc(e: ^ast.Expr) -> string {
	expr := ast.unparen_expr(e)
	for expr != nil {
		if field, is_field := expr.derived_expr.(^ast.Field_Value); is_field {
			expr = ast.unparen_expr(field.value)
			continue
		}
		if soft, is_soft := expr.derived_expr.(^ast.Auto_Cast); is_soft {
			expr = ast.unparen_expr(soft.expr)
			continue
		}
		if typed, is_typed := expr.derived_expr.(^ast.Type_Cast); is_typed {
			expr = ast.unparen_expr(typed.expr)
			continue
		}
		unary, is_unary := expr.derived_expr.(^ast.Unary_Expr)
		if !is_unary || unary.op.kind != .And {
			return ""
		}
		expr = ast.unparen_expr(unary.expr)
		if expr == nil {
			return ""
		}
		if _, again := expr.derived_expr.(^ast.Unary_Expr); again {
			continue
		}
		ident, is_ident := expr.derived_expr.(^ast.Ident)
		if !is_ident {
			return ""
		}
		return ident.name
	}
	return ""
}

@(private = "file")
borrowed_escape_invalidate :: proc(p: ^Borrowed_Escape_Proc, name: string) {
	if name == "" {
		return
	}
	prev, found := p.bindings[name]
	if !found || prev.kind != .Borrowed {
		return
	}
	borrowed_escape_assign(p, name, Borrowed_Escape_Binding{origin = prev.origin})
}

@(private = "file")
borrowed_escape_note_address :: proc(p: ^Borrowed_Escape_Proc, e: ^ast.Expr) {
	name := borrowed_escape_pointer_arg(e)
	if name == "" {
		return
	}
	b, found := p.bindings[name]
	if !found || b.kind == .Stack {
		return
	}
	p.addressed[name] = true
}

@(private = "file")
borrowed_escape_invalidate_addressed :: proc(p: ^Borrowed_Escape_Proc) {
	for name in p.addressed {
		borrowed_escape_invalidate(p, name)
	}
}

// A dereference store can rewrite any borrowed header whose address was
// taken. (&name)^ names its target; p^ does not, so every such header drops.
@(private = "file")
borrowed_escape_deref_store :: proc(p: ^Borrowed_Escape_Proc, lhs: ^ast.Expr) -> bool {
	expr := ast.unparen_expr(lhs)
	if expr == nil {
		return false
	}
	deref, ok := expr.derived_expr.(^ast.Deref_Expr)
	if !ok {
		return false
	}
	borrowed_escape_invalidate(p, borrowed_escape_pointer_arg(deref.expr))
	return true
}

@(private = "file")
borrowed_escape_scan_call :: proc(p: ^Borrowed_Escape_Proc, call: ^ast.Call_Expr) {
	if call == nil {
		return
	}
	borrowed_escape_scan_expr(p, call.expr)
	for arg in call.args {
		borrowed_escape_invalidate(p, borrowed_escape_pointer_arg(arg))
		borrowed_escape_scan_expr(p, arg)
	}
	// A previously escaped address may reach this call through a pointer
	// alias or global state. Only the builtin string conversion is pure.
	if !borrowed_escape_builtin_string(p, call) {
		borrowed_escape_invalidate_addressed(p)
	}
}

// borrowed_escape_scan_expr drops a borrowed header when its address is a
// call argument, and records &header so a later dereference store can drop it.
// Nested procedure bodies are separate checks and are not walked here.
@(private = "file")
borrowed_escape_scan_expr :: proc(p: ^Borrowed_Escape_Proc, e: ^ast.Expr) {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return
	}
	#partial switch n in expr.derived_expr {
	case ^ast.Call_Expr:
		borrowed_escape_scan_call(p, n)
	case ^ast.Selector_Call_Expr:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_scan_call(p, n.call)
	case ^ast.Unary_Expr:
		borrowed_escape_note_address(p, expr)
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Deref_Expr:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Binary_Expr:
		borrowed_escape_scan_expr(p, n.left)
		borrowed_escape_scan_expr(p, n.right)
	case ^ast.Selector_Expr:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Index_Expr:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_scan_expr(p, n.index)
	case ^ast.Slice_Expr:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_scan_expr(p, n.low)
		borrowed_escape_scan_expr(p, n.high)
	case ^ast.Matrix_Index_Expr:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_scan_expr(p, n.row_index)
		borrowed_escape_scan_expr(p, n.column_index)
	case ^ast.Type_Cast:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Auto_Cast:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Ternary_If_Expr:
		borrowed_escape_scan_expr(p, n.x)
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_scan_expr(p, n.y)
	case ^ast.Ternary_When_Expr:
		borrowed_escape_scan_expr(p, n.x)
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_scan_expr(p, n.y)
	case ^ast.Or_Else_Expr:
		borrowed_escape_scan_expr(p, n.x)
		borrowed_escape_scan_expr(p, n.y)
	case ^ast.Or_Return_Expr:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Or_Branch_Expr:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Ellipsis:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Field_Value:
		borrowed_escape_scan_expr(p, n.value)
	case ^ast.Comp_Lit:
		borrowed_escape_scan_expr(p, n.type)
		for elem in n.elems {
			borrowed_escape_scan_expr(p, elem)
		}
	case ^ast.Tag_Expr:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Proc_Lit:
		return
	}
}

@(private = "file")
borrowed_escape_ident :: proc(e: ^ast.Expr) -> string {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return ""
	}
	if id, ok := expr.derived_expr.(^ast.Ident); ok {
		return id.name
	}
	if unary, ok := expr.derived_expr.(^ast.Unary_Expr); ok {
		return borrowed_escape_ident(unary.expr)
	}
	return ""
}

// borrowed_escape_fixed is a stack array or an inline [dynamic; N]T.
// A slice type has a nil length and is not fixed.
@(private = "file")
borrowed_escape_fixed :: proc(e: ^ast.Expr) -> (byte_elem: bool, elem: ^ast.Expr, ok: bool) {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return
	}
	#partial switch n in expr.derived_expr {
	case ^ast.Array_Type:
		if n.len == nil {
			return
		}
		return borrowed_escape_is_byte(n.elem), n.elem, true
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return borrowed_escape_is_byte(n.elem), n.elem, true
	}
	return
}

@(private = "file")
borrowed_escape_is_byte :: proc(e: ^ast.Expr) -> bool {
	return borrowed_escape_ident(e) == "u8" || borrowed_escape_ident(e) == "byte"
}

@(private = "file")
borrowed_escape_slice_type :: proc(e: ^ast.Expr) -> bool {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return false
	}
	array, ok := expr.derived_expr.(^ast.Array_Type)
	return ok && array.len == nil
}

@(private = "file")
borrowed_escape_enduring :: proc(decl: ^ast.Value_Decl) -> bool {
	for attr in decl.attributes {
		for elem in attr.elems {
			name: string
			value: ^ast.Expr
			#partial switch e in elem.derived_expr {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				name = borrowed_escape_ident(e.field)
				value = e.value
			}
			if name != "static" && name != "thread_local" {
				continue
			}
			if value != nil && borrowed_escape_ident(value) == "false" {
				continue
			}
			return true
		}
	}
	return false
}

// borrowed_escape_view_array is an expression whose bytes are inline in a
// local fixed array. Indexing stops at the first element that is not one.
@(private = "file")
borrowed_escape_view_array :: proc(
	p: ^Borrowed_Escape_Proc,
	e: ^ast.Expr,
) -> (
	view: Borrowed_Escape_Binding,
	ok: bool,
) {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return
	}
	#partial switch n in expr.derived_expr {
	case ^ast.Ident:
		b, found := p.bindings[n.name]
		if found && b.kind == .Stack {
			return b, true
		}
	case ^ast.Comp_Lit:
		if n.type == nil {
			return
		}
		byte_elem, elem, fixed := borrowed_escape_fixed(n.type)
		if !fixed {
			return
		}
		return Borrowed_Escape_Binding {
			kind = .Stack,
			byte_elem = byte_elem,
			elem = elem,
			origin = n.pos.line,
		}, true
	case ^ast.Index_Expr:
		if parent, parent_ok := borrowed_escape_view_array(p, n.expr); parent_ok {
			byte_elem, elem, inner := borrowed_escape_fixed(parent.elem)
			if inner {
				parent.byte_elem = byte_elem
				parent.elem = elem
				return parent, true
			}
		}
		base := borrowed_escape_classify(p, n.expr)
		if base.kind == .Borrowed {
			byte_elem, elem, inner := borrowed_escape_fixed(base.elem)
			if inner {
				base.kind = .Stack
				base.byte_elem = byte_elem
				base.elem = elem
				base.as_string = false
				return base, true
			}
		}
	}
	return
}

@(private = "file")
borrowed_escape_builtin_string :: proc(p: ^Borrowed_Escape_Proc, call: ^ast.Call_Expr) -> bool {
	if p.file.string_shadow || len(call.args) != 1 {
		return false
	}
	if borrowed_escape_ident(call.expr) != "string" {
		return false
	}
	if _, found := p.bindings["string"]; found {
		return false
	}
	return true
}

@(private = "file")
borrowed_escape_classify :: proc(p: ^Borrowed_Escape_Proc, e: ^ast.Expr) -> Borrowed_Escape_Binding {
	expr := ast.unparen_expr(e)
	if expr == nil {
		return {}
	}
	#partial switch n in expr.derived_expr {
	case ^ast.Ident:
		b, found := p.bindings[n.name]
		if !found || b.kind == .None {
			return {}
		}
		return b
	case ^ast.Slice_Expr:
		if view, view_ok := borrowed_escape_view_array(p, n.expr); view_ok {
			return {
				kind      = .Borrowed,
				array     = view.array,
				byte_elem = view.byte_elem,
				elem      = view.elem,
				origin    = n.pos.line,
			}
		}
		base := borrowed_escape_classify(p, n.expr)
		if base.kind == .Borrowed {
			base.as_string = false
			return base
		}
	case ^ast.Comp_Lit:
		byte_elem, elem, fixed := borrowed_escape_fixed(n.type)
		if fixed {
			return {
				kind      = .Stack,
				byte_elem = byte_elem,
				elem      = elem,
				origin    = n.pos.line,
			}
		}
	case ^ast.Call_Expr:
		if !borrowed_escape_builtin_string(p, n) {
			return {}
		}
		arg := n.args[0]
		if field, is_field := arg.derived_expr.(^ast.Field_Value); is_field {
			arg = field.value
		}
		inner := borrowed_escape_classify(p, arg)
		if inner.kind == .Borrowed && inner.byte_elem {
			inner.as_string = true
			return inner
		}
	case ^ast.Type_Cast:
		inner := borrowed_escape_classify(p, n.expr)
		if inner.kind != .Borrowed {
			return {}
		}
		type_name := borrowed_escape_ident(n.type)
		if n.tok.kind == .Transmute && type_name == "string" {
			inner.as_string = true
			return inner
		}
		if n.tok.kind == .Cast && type_name == "string" && inner.byte_elem {
			inner.as_string = true
			return inner
		}
		if n.tok.kind == .Cast && borrowed_escape_slice_type(n.type) {
			inner.as_string = false
			return inner
		}
	}
	return {}
}

@(private = "file")
borrowed_escape_walk_stmt :: proc(p: ^Borrowed_Escape_Proc, stmt: ^ast.Stmt) {
	if stmt == nil {
		return
	}
	#partial switch n in stmt.derived_stmt {
	case ^ast.Block_Stmt:
		borrowed_escape_push_decl(p)
		for child in n.stmts {
			borrowed_escape_walk_stmt(p, child)
		}
		borrowed_escape_pop_decl(p)
	case ^ast.If_Stmt:
		borrowed_escape_push_decl(p)
		borrowed_escape_walk_stmt(p, n.init)
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_push_cond(p, false)
		borrowed_escape_walk_stmt(p, n.body)
		borrowed_escape_pop_cond(p)
		if n.else_stmt != nil {
			borrowed_escape_push_cond(p, false)
			borrowed_escape_walk_stmt(p, n.else_stmt)
			borrowed_escape_pop_cond(p)
		}
		borrowed_escape_pop_decl(p)
	case ^ast.When_Stmt:
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_push_cond(p, false)
		borrowed_escape_walk_stmt(p, n.body)
		borrowed_escape_pop_cond(p)
		if n.else_stmt != nil {
			borrowed_escape_push_cond(p, false)
			borrowed_escape_walk_stmt(p, n.else_stmt)
			borrowed_escape_pop_cond(p)
		}
	case ^ast.For_Stmt:
		borrowed_escape_push_decl(p)
		borrowed_escape_walk_stmt(p, n.init)
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_push_cond(p, false)
		borrowed_escape_walk_stmt(p, n.body)
		borrowed_escape_walk_stmt(p, n.post)
		borrowed_escape_pop_cond(p)
		borrowed_escape_pop_decl(p)
	case ^ast.Range_Stmt:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_range(p, n.vals, n.body)
	case ^ast.Inline_Range_Stmt:
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_range(p, ([]^ast.Expr{n.val0, n.val1}), n.body)
	case ^ast.Switch_Stmt:
		borrowed_escape_push_decl(p)
		borrowed_escape_walk_stmt(p, n.init)
		borrowed_escape_scan_expr(p, n.cond)
		borrowed_escape_walk_stmt(p, n.body)
		borrowed_escape_pop_decl(p)
	case ^ast.Type_Switch_Stmt:
		borrowed_escape_push_decl(p)
		borrowed_escape_walk_stmt(p, n.tag)
		borrowed_escape_scan_expr(p, n.expr)
		borrowed_escape_walk_stmt(p, n.body)
		borrowed_escape_pop_decl(p)
	case ^ast.Case_Clause:
		for expr in n.list {
			borrowed_escape_scan_expr(p, expr)
		}
		borrowed_escape_push_cond(p, false)
		borrowed_escape_push_decl(p)
		for child in n.body {
			borrowed_escape_walk_stmt(p, child)
		}
		borrowed_escape_pop_decl(p)
		borrowed_escape_pop_cond(p)
	case ^ast.Defer_Stmt:
		p.defer_depth += 1
		borrowed_escape_push_cond(p, true)
		borrowed_escape_walk_stmt(p, n.stmt)
		borrowed_escape_pop_cond(p)
		p.defer_depth -= 1
	case ^ast.Return_Stmt:
		borrowed_escape_return(p, n)
	case ^ast.Assign_Stmt:
		borrowed_escape_assign_stmt(p, n)
	case ^ast.Value_Decl:
		borrowed_escape_value_decl(p, n)
	case ^ast.Expr_Stmt:
		borrowed_escape_scan_expr(p, n.expr)
	case ^ast.Tag_Stmt:
		borrowed_escape_walk_stmt(p, n.stmt)
	}
}

@(private = "file")
borrowed_escape_range :: proc(p: ^Borrowed_Escape_Proc, vals: []^ast.Expr, body: ^ast.Stmt) {
	borrowed_escape_push_decl(p)
	for val in vals {
		borrowed_escape_define(p, borrowed_escape_ident(val), {})
	}
	borrowed_escape_push_cond(p, false)
	borrowed_escape_walk_stmt(p, body)
	borrowed_escape_pop_cond(p)
	borrowed_escape_pop_decl(p)
}

@(private = "file")
borrowed_escape_value_decl :: proc(p: ^Borrowed_Escape_Proc, n: ^ast.Value_Decl) {
	for value in n.values {
		borrowed_escape_scan_expr(p, value)
	}
	if !n.is_mutable || borrowed_escape_enduring(n) {
		for name in n.names {
			borrowed_escape_define(p, borrowed_escape_ident(name), {})
		}
		return
	}
	if n.type != nil {
		byte_elem, elem, fixed := borrowed_escape_fixed(n.type)
		if fixed {
			for name_expr in n.names {
				name := borrowed_escape_ident(name_expr)
				borrowed_escape_define(
					p,
					name,
					{
						kind      = .Stack,
						array     = name,
						byte_elem = byte_elem,
						elem      = elem,
						origin    = n.pos.line,
					},
				)
			}
			return
		}
	}
	if len(n.names) == len(n.values) {
		for name_expr, i in n.names {
			name := borrowed_escape_ident(name_expr)
			b := borrowed_escape_classify(p, n.values[i])
			b.result = false
			b.frame = 0
			if b.kind == .Stack {
				b.array = name
				b.as_string = false
			}
			if b.origin == 0 {
				b.origin = n.pos.line
			}
			borrowed_escape_define(p, name, b)
		}
		return
	}
	for name in n.names {
		borrowed_escape_define(p, borrowed_escape_ident(name), {})
	}
}

@(private = "file")
borrowed_escape_assign_stmt :: proc(p: ^Borrowed_Escape_Proc, n: ^ast.Assign_Stmt) {
	for rhs in n.rhs {
		borrowed_escape_scan_expr(p, rhs)
	}
	stored := false
	for lhs in n.lhs {
		if borrowed_escape_deref_store(p, lhs) {
			stored = true
		}
	}
	if stored {
		borrowed_escape_invalidate_addressed(p)
	}
	if n.op.kind != .Eq {
		return
	}
	if len(n.lhs) == len(n.rhs) {
		for lhs, i in n.lhs {
			name := borrowed_escape_ident(lhs)
			b := borrowed_escape_classify(p, n.rhs[i])
			if b.kind == .Stack {
				b.array = name
				b.as_string = false
			}
			if b.origin == 0 {
				b.origin = n.pos.line
			}
			borrowed_escape_assign(p, name, b)
		}
		return
	}
	for lhs in n.lhs {
		borrowed_escape_assign(p, borrowed_escape_ident(lhs), {origin = n.pos.line})
	}
}

@(private = "file")
borrowed_escape_return :: proc(p: ^Borrowed_Escape_Proc, n: ^ast.Return_Stmt) {
	for expr in n.results {
		borrowed_escape_scan_expr(p, expr)
	}
	if p.defer_depth > 0 {
		return
	}
	if len(n.results) == 0 {
		for name in p.results {
			b, found := p.bindings[name]
			if found && b.result && b.kind == .Borrowed {
				borrowed_escape_report(p, b, n.pos.line)
				return
			}
		}
		return
	}
	for expr in n.results {
		b := borrowed_escape_classify(p, expr)
		if b.kind == .Borrowed {
			borrowed_escape_report(p, b, n.pos.line)
			return
		}
	}
}

@(private = "file")
borrowed_escape_report :: proc(p: ^Borrowed_Escape_Proc, b: Borrowed_Escape_Binding, ret_line: int) {
	line := ret_line
	if !p.file.added[line] {
		line = b.origin
	}
	if line == 0 || !p.file.added[line] {
		return
	}
	prev := context.allocator
	context.allocator = p.file.alloc
	defer context.allocator = prev

	what := "a temporary local array"
	if b.array != "" {
		what = fmt.aprintf("local array `%s`", b.array)
	}
	msg: string
	if b.as_string {
		msg = fmt.aprintf(
			"returns a string aliased to %s; string([]u8), cast(string) and transmute(string) share those bytes and do not copy",
			what,
		)
	} else {
		msg = fmt.aprintf(
			"returns a slice of %s; that stack storage ends when the procedure returns",
			what,
		)
	}
	append(
		p.file.out,
		static(
			"odin-borrowed-escape",
			.Must_Fix,
			msg,
			"copy into caller-owned or heap storage before returning; use strings.clone for a string that aliases a byte slice",
			file = p.file.path,
			line = line,
			symbol = b.array,
		),
	)
}
