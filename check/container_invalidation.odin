package check

// A dynamic array's element storage may move when a growth call asks for
// more capacity than the header already has. append, reserve, resize and
// inject_at are that call. This pass reports a use of a pointer or slice
// taken from that storage when the same procedure cannot prove the call
// stays inside the existing allocation.
//
// Helpers, nested-procedure captures, defer, assign_at and shrink are
// odin-container-invalidation-indirect. A zero-sized element type has no
// element storage to invalidate, and a fixed-capacity array never moves.
// A growth call whose result is bound is not proof: failure can leave the
// old pointer valid, and this pass does not split that path.

import "base:runtime"
import "core:odin/ast"
import "core:strings"

import "../finding"


// check_container_invalidation reports local borrows used after growth.
// Mutations hidden in callees, nested procedures or defer require inference.
check_container_invalidation :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	container_invalidation_check(s, out)
}

@(private = "file")
container_invalidation_check :: proc(
	s: Scope,
	out: ^[dynamic]finding.Finding,
	allocator := context.allocator,
	scratch := context.temp_allocator,
) {
	keep := allocator
	context.allocator = scratch
	context.temp_allocator = scratch
	added := make(map[int]bool, context.temp_allocator)
	for path in sorted_keys(s.c.added) {
		if !strings.has_suffix(path, ".odin") || is_test_file(path) {
			continue
		}
		src, ok := s.sources[path]
		if !ok {
			continue
		}
		clear(&added)
		for line in s.c.added[path] {
			added[line.line] = true
		}
		container_invalidation_file(path, string(src), added, out, keep)
	}
}

@(private = "file")
container_invalidation_file :: proc(
	path, src: string,
	added: map[int]bool,
	out: ^[dynamic]finding.Finding,
	keep: runtime.Allocator,
) {
	file := parse_odin_source(path, src)
	if file == nil {
		return
	}
	base := container_invalidation_state(path, added, out, keep)
	for decl in file.decls {
		container_invalidation_file_decl(&base, decl)
	}
	base.file_base = &base
	for decl in file.decls {
		container_invalidation_file_procs(&base, decl)
	}
}

@(private = "file")
container_invalidation_file_decl :: proc(s: ^Container_Invalidation_State, decl: ^ast.Stmt) {
	#partial switch n in decl.derived_stmt {
	case ^ast.Import_Decl:
		container_invalidation_import(s, n)
	case ^ast.Value_Decl:
		container_invalidation_top_value(s, n)
	}
}

@(private = "file")
container_invalidation_import :: proc(s: ^Container_Invalidation_State, n: ^ast.Import_Decl) {
	name := n.name.text
	if name == "" || name == "_" {
		rel := strings.trim(n.relpath.text, "\"")
		if cut := strings.last_index_any(rel, ":/"); cut >= 0 {
			name = rel[cut + 1:]
		} else {
			name = rel
		}
	}
	container_invalidation_shadow_raw(s, name)
}

@(private = "file")
container_invalidation_top_value :: proc(s: ^Container_Invalidation_State, n: ^ast.Value_Decl) {
	if len(n.names) != 1 {
		for name in n.names {
			container_invalidation_shadow_raw(s, container_invalidation_ident(name))
		}
		return
	}
	name := container_invalidation_ident(n.names[0])
	if name == "" || name == "_" {
		return
	}
	container_invalidation_shadow_raw(s, name)
	if n.is_mutable {
		if container_invalidation_dyn(s, n.type) != nil ||
		   (len(n.values) == 1 && container_invalidation_make_type(s, n.values[0]) != nil) {
			container_invalidation_bind_unknown(s, name, n.type, n.values)
		}
		return
	}
	if len(n.values) != 1 {
		return
	}
	value := n.values[0]
	if n, ok := container_invalidation_int(s, value); ok {
		s.consts[name] = n
		return
	}
	if container_invalidation_is_type(value) || container_invalidation_dyn(s, value) != nil {
		s.types[name] = ast.unparen_expr(value)
	}
}

@(private = "file")
container_invalidation_bind_unknown :: proc(
	s: ^Container_Invalidation_State,
	name: string,
	typ: ^ast.Expr,
	values: []^ast.Expr,
) {
	name := name
	info := container_invalidation_dyn(s, typ)
	if info == nil && len(values) == 1 {
		info = container_invalidation_make_type(s, values[0])
	}
	if info == nil {
		return
	}
	// Another procedure may already have grown a package-level array.
	id := container_invalidation_storage(s, info)
	s.headers[name] = Container_Invalidation_Header {
		storage = id,
		epoch   = s.storages[id].epoch,
	}
}

@(private = "file")
container_invalidation_file_procs :: proc(s: ^Container_Invalidation_State, decl: ^ast.Stmt) {
	#partial switch n in decl.derived_stmt {
	case ^ast.Value_Decl:
		for value in n.values {
			container_invalidation_nested_procs(s, value)
		}
	}
}

@(private = "file")
container_invalidation_nested_procs :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) {
	if e == nil {
		return
	}
	#partial switch n in e.derived_expr {
	case ^ast.Proc_Lit:
		container_invalidation_proc(s, n)
	case ^ast.Paren_Expr:
		container_invalidation_nested_procs(s, n.expr)
	}
}

@(private = "file")
container_invalidation_proc :: proc(base: ^Container_Invalidation_State, n: ^ast.Proc_Lit) {
	if n.body == nil || n.type == nil {
		return
	}
	s := container_invalidation_clone(base)
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(&s, &frame)
	if n.type.params != nil {
		for field in n.type.params.list {
			container_invalidation_param(&s, &frame, field)
		}
	}
	container_invalidation_stmt(&s, n.body, &frame)
}

@(private = "file")
container_invalidation_param :: proc(
	s: ^Container_Invalidation_State,
	frame: ^Container_Invalidation_Frame,
	field: ^ast.Field,
) {
	info := container_invalidation_dyn(s, field.type)
	indirect := false
	typ := container_invalidation_unparen(field.type)
	if info == nil && typ != nil {
		if ptr, ok := typ.derived_expr.(^ast.Pointer_Type);
		   ok {
			info = container_invalidation_dyn(s, ptr.elem)
			indirect = info != nil
		}
	}
	for name_expr in field.names {
		name := container_invalidation_ident(name_expr)
		if name == "" || name == "_" {
			continue
		}
		container_invalidation_note(s, frame, name)
		container_invalidation_clear_binding(s, name)
		container_invalidation_shadow_raw(s, name)
		if info == nil {
			continue
		}
		id := container_invalidation_storage(s, info)
		s.headers[name] = Container_Invalidation_Header {
			storage  = id,
			epoch    = s.storages[id].epoch,
			indirect = indirect,
		}
	}
}

@(private = "file")
container_invalidation_stmt :: proc(
	s: ^Container_Invalidation_State,
	stmt: ^ast.Stmt,
	frame: ^Container_Invalidation_Frame,
) {
	if stmt == nil || s.halt != .None {
		return
	}
	#partial switch n in stmt.derived_stmt {
	case ^ast.Empty_Stmt, ^ast.Bad_Stmt, ^ast.Bad_Decl:
	case ^ast.Value_Decl:
		container_invalidation_value(s, frame, n)
	case ^ast.Assign_Stmt:
		container_invalidation_assign(s, n)
	case ^ast.Expr_Stmt:
		container_invalidation_expr(s, n.expr)
	case ^ast.Block_Stmt:
		container_invalidation_stmts(s, n.stmts)
	case ^ast.If_Stmt:
		container_invalidation_if(s, n)
	case ^ast.When_Stmt:
		container_invalidation_when(s, n)
	case ^ast.For_Stmt:
		container_invalidation_for(s, n)
	case ^ast.Range_Stmt:
		container_invalidation_range(s, n)
	case ^ast.Switch_Stmt:
		container_invalidation_switch(s, n.body, n.init, n.cond)
	case ^ast.Type_Switch_Stmt:
		container_invalidation_switch(s, n.body, n.tag, n.expr)
	case ^ast.Return_Stmt:
		for result in n.results {
			container_invalidation_expr(s, result)
		}
		s.halt = .Return
	case ^ast.Branch_Stmt:
		if n.tok.kind == .Break || n.tok.kind == .Continue {
			s.halt = .Break
		}
	case ^ast.Defer_Stmt:
		// defer runs on the way out, after later growth. Ordering it
		// here would both miss that use and invent one. Inference owns it.
	case ^ast.Inline_Range_Stmt:
		container_invalidation_unroll(s, n)
	}
}

@(private = "file")
container_invalidation_stmts :: proc(s: ^Container_Invalidation_State, stmts: []^ast.Stmt) {
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	for stmt in stmts {
		if s.halt != .None {
			return
		}
		container_invalidation_stmt(s, stmt, &frame)
	}
}

@(private = "file")
container_invalidation_value :: proc(
	s: ^Container_Invalidation_State,
	frame: ^Container_Invalidation_Frame,
	n: ^ast.Value_Decl,
	allocator := context.temp_allocator,
) {
	context.temp_allocator = allocator
	// Shadow the new names before the values, so a nested procedure
	// whose name hides a builtin does not see the builtin.
	for name_expr in n.names {
		container_invalidation_note(s, frame, container_invalidation_ident(name_expr))
		container_invalidation_shadow_raw(s, container_invalidation_ident(name_expr))
	}
	saved := s.observe
	s.observe = true
	for value in n.values {
		container_invalidation_expr(s, value)
	}
	s.observe = saved
	if s.halt != .None {
		return
	}
	if !n.is_mutable && len(n.names) == 1 && len(n.values) == 1 {
		name := container_invalidation_ident(n.names[0])
		if name == "" || name == "_" {
			return
		}
		container_invalidation_clear_binding(s, name)
		if num, ok := container_invalidation_int(s, n.values[0]); ok {
			s.consts[name] = num
		} else if container_invalidation_is_type(n.values[0]) {
			s.types[name] = ast.unparen_expr(n.values[0])
		}
		return
	}
	// Classify initializers before replacing the bindings they can shadow.
	Pending :: struct {
		name: string,
		spec: Container_Invalidation_Spec,
	}
	pending := make([dynamic]Pending, context.temp_allocator)
	for name_expr, i in n.names {
		name := container_invalidation_ident(name_expr)
		if name == "" || name == "_" {
			continue
		}
		value: ^ast.Expr
		if i < len(n.values) {
			value = n.values[i]
		}
		append(&pending, Pending{name, container_invalidation_classify(s, n.type, value, name_expr.pos.line)})
	}
	for item in pending {
		container_invalidation_clear_binding(s, item.name)
		container_invalidation_install(s, item.name, item.spec)
	}
}

@(private = "file")
container_invalidation_assign :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Assign_Stmt,
	allocator := context.temp_allocator,
) {
	context.temp_allocator = allocator
	saved := s.observe
	s.observe = true
	for rhs in n.rhs {
		container_invalidation_expr(s, rhs)
	}
	s.observe = saved
	if s.halt != .None || n.op.kind != .Eq {
		return
	}
	Pending :: struct {
		name: string,
		spec: Container_Invalidation_Spec,
	}
	pending := make([dynamic]Pending, context.temp_allocator)
	for lhs, i in n.lhs {
		rhs: ^ast.Expr
		if i < len(n.rhs) {
			rhs = n.rhs[i]
		} else if len(n.rhs) == 1 {
			rhs = n.rhs[0]
		}
		if id := container_invalidation_ident(lhs); id != "" && id != "_" {
			append(&pending, Pending{id, container_invalidation_classify(s, nil, rhs, lhs.pos.line)})
			continue
		}
		container_invalidation_write_target(s, lhs)
	}
	for item in pending {
		delete_key(&s.borrows, item.name)
		delete_key(&s.aliases, item.name)
		delete_key(&s.headers, item.name)
	}
	for item in pending {
		container_invalidation_install(s, item.name, item.spec)
	}
}

@(private = "file")
container_invalidation_if :: proc(s: ^Container_Invalidation_State, n: ^ast.If_Stmt) {
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	if n.init != nil {
		container_invalidation_stmt(s, n.init, &frame)
	}
	container_invalidation_observe_expr(s, n.cond)
	if s.halt != .None {
		return
	}
	take_then, take_else := true, n.else_stmt != nil
	if container_invalidation_bool(s, n.cond) == .True {
		take_else = false
	} else if container_invalidation_bool(s, n.cond) == .False {
		take_then = false
	}
	if take_then && !take_else {
		container_invalidation_stmt(s, n.body, &frame)
		return
	}
	if take_else && !take_then {
		container_invalidation_stmt(s, n.else_stmt, &frame)
		return
	}
	then := container_invalidation_clone(s)
	container_invalidation_stmt(&then, n.body, nil)
	els := container_invalidation_clone(s)
	if n.else_stmt != nil {
		container_invalidation_stmt(&els, n.else_stmt, nil)
	}
	container_invalidation_join(s, &then, &els)
}

@(private = "file")
container_invalidation_when :: proc(s: ^Container_Invalidation_State, n: ^ast.When_Stmt) {
	// A non-literal when is one build or the other. Facts from the branch
	// that this build discarded must not escape, and must not be required.
	// The branch that is compiled is still checked on its own.
	cond := container_invalidation_bool(s, n.cond)
	if cond == .True {
		container_invalidation_stmt(s, n.body, nil)
		return
	}
	if cond == .False {
		if n.else_stmt != nil {
			container_invalidation_stmt(s, n.else_stmt, nil)
		}
		return
	}
	then := container_invalidation_clone(s)
	container_invalidation_stmt(&then, n.body, nil)
	if n.else_stmt != nil {
		els := container_invalidation_clone(s)
		container_invalidation_stmt(&els, n.else_stmt, nil)
	}
}

@(private = "file")
container_invalidation_for :: proc(s: ^Container_Invalidation_State, n: ^ast.For_Stmt) {
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	if n.init != nil {
		container_invalidation_stmt(s, n.init, &frame)
	}
	container_invalidation_observe_expr(s, n.cond)
	if s.halt != .None {
		return
	}
	if container_invalidation_bool(s, n.cond) == .False {
		return
	}
	must := n.cond == nil || container_invalidation_bool(s, n.cond) == .True
	container_invalidation_loop(s, n.body, must, 0, false)
}

@(private = "file")
container_invalidation_range :: proc(s: ^Container_Invalidation_State, n: ^ast.Range_Stmt) {
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	if n.init != nil {
		container_invalidation_stmt(s, n.init, &frame)
	}
	container_invalidation_expr(s, n.expr)
	if s.halt != .None {
		return
	}
	trips, known := container_invalidation_trips(s, n.expr)
	if known && trips == 0 {
		return
	}
	inner := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &inner)
	for val in n.vals {
		container_invalidation_range_val(s, &inner, val, n.expr)
	}
	container_invalidation_loop(s, n.body, known && trips > 0, trips if known else 0, known)
}

@(private = "file")
container_invalidation_unroll :: proc(s: ^Container_Invalidation_State, n: ^ast.Inline_Range_Stmt) {
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	container_invalidation_expr(s, n.expr)
	if s.halt != .None {
		return
	}
	trips, known := container_invalidation_trips(s, n.expr)
	if known && trips == 0 {
		return
	}
	if n.val0 != nil {
		container_invalidation_range_val(s, &frame, n.val0, n.expr)
	}
	if n.val1 != nil {
		container_invalidation_range_val(s, &frame, n.val1, n.expr)
	}
	container_invalidation_loop(s, n.body, known && trips > 0, trips if known else 0, known)
}

@(private = "file")
container_invalidation_range_val :: proc(
	s: ^Container_Invalidation_State,
	frame: ^Container_Invalidation_Frame,
	val, range_expr: ^ast.Expr,
) {
	name := ""
	borrow := false
	#partial switch n in container_invalidation_unparen(val).derived_expr {
	case ^ast.Ident:
		name = n.name
	case ^ast.Unary_Expr:
		if n.op.kind == .And {
			name = container_invalidation_ident(n.expr)
			borrow = name != ""
		}
	}
	if name == "" || name == "_" {
		return
	}
	container_invalidation_note(s, frame, name)
	container_invalidation_clear_binding(s, name)
	container_invalidation_shadow_raw(s, name)
	if !borrow {
		return
	}
	if ref, ok := container_invalidation_storage_of_expr(s, range_expr); ok {
		s.borrows[name] = Container_Invalidation_Borrow {
			storage = ref,
			epoch   = s.storages[ref].epoch,
			line    = val.pos.line,
			array   = container_invalidation_array_name(s, range_expr, ref),
		}
	}
}

@(private = "file")
container_invalidation_loop :: proc(
	s: ^Container_Invalidation_State,
	body: ^ast.Stmt,
	must: bool,
	trips: int,
	trips_known: bool,
) {
	scan := container_invalidation_scan_stmt(s, body)
	if scan.ok && !scan.resets && !container_invalidation_loop_fits(s, scan, trips_known, trips) {
		scan.ok = false
	}
	entry_len := container_invalidation_len_snapshot(s)
	if scan.ok && scan.resets {
		container_invalidation_loop_reset(s, body, entry_len, must, trips, trips_known)
		return
	}
	if scan.ok {
		container_invalidation_stmt(s, body, nil)
		if s.halt == .Break {
			s.halt = .None
		}
		if s.halt != .Return {
			times := trips if trips_known else 1
			container_invalidation_apply_added(s, entry_len, scan, times)
		}
		return
	}
	working := container_invalidation_clone(s)
	old := working.repeating
	working.repeating = true
	container_invalidation_stmt(&working, body, nil)
	working.repeating = old
	if working.halt == .Break {
		working.halt = .None
	}
	if must {
		container_invalidation_replace(s, &working)
		return
	}
	stay := container_invalidation_clone(s)
	container_invalidation_join(s, &stay, &working)
}

@(private = "file")
container_invalidation_switch :: proc(
	s: ^Container_Invalidation_State,
	body, init: ^ast.Stmt,
	cond: ^ast.Expr,
	allocator := context.temp_allocator,
) {
	context.temp_allocator = allocator
	frame := container_invalidation_frame()
	defer container_invalidation_frame_pop(s, &frame)
	if init != nil {
		container_invalidation_stmt(s, init, &frame)
	}
	container_invalidation_observe_expr(s, cond)
	if s.halt != .None || body == nil {
		return
	}
	block, ok := body.derived_stmt.(^ast.Block_Stmt)
	if !ok {
		container_invalidation_stmt(s, body, &frame)
		return
	}
	arms := make([dynamic]Container_Invalidation_State, context.temp_allocator)
	saw_default := false
	for stmt in block.stmts {
		clause, is_case := stmt.derived_stmt.(^ast.Case_Clause)
		if !is_case {
			continue
		}
		if len(clause.list) == 0 {
			saw_default = true
		}
		arm := container_invalidation_clone(s)
		container_invalidation_stmts(&arm, clause.body)
		if arm.halt == .Break {
			arm.halt = .None
		}
		append(&arms, arm)
	}
	if !saw_default {
		append(&arms, container_invalidation_clone(s))
	}
	if len(arms) == 0 {
		return
	}
	acc := arms[0]
	for i in 1 ..< len(arms) {
		next := arms[i]
		container_invalidation_join(&acc, &acc, &next)
	}
	container_invalidation_replace(s, &acc)
}

@(private = "file")
container_invalidation_expr :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) {
	if e == nil || s.halt != .None {
		return
	}
	#partial switch n in e.derived_expr {
	case ^ast.Ident:
		container_invalidation_use_borrow(s, n.name, e.pos.line)
	case ^ast.Paren_Expr:
		container_invalidation_expr(s, n.expr)
	case ^ast.Selector_Expr:
		container_invalidation_expr(s, n.expr)
	case ^ast.Unary_Expr:
		// `&p` names the variable, not the element it borrows. The address
		// can be used to store a new pointer into p.
		if n.op.kind == .And && container_invalidation_mark_address(s, n.expr) {
			return
		}
		container_invalidation_expr(s, n.expr)
	case ^ast.Binary_Expr:
		container_invalidation_expr(s, n.left)
		container_invalidation_expr(s, n.right)
	case ^ast.Index_Expr:
		container_invalidation_expr(s, n.expr)
		container_invalidation_expr(s, n.index)
		container_invalidation_use_storage_expr(s, n.expr, e.pos.line)
	case ^ast.Slice_Expr:
		container_invalidation_expr(s, n.expr)
		container_invalidation_expr(s, n.low)
		container_invalidation_expr(s, n.high)
		container_invalidation_use_storage_expr(s, n.expr, e.pos.line)
	case ^ast.Deref_Expr:
		container_invalidation_expr(s, n.expr)
		container_invalidation_use_storage_expr(s, n.expr, e.pos.line)
	case ^ast.Type_Cast, ^ast.Auto_Cast:
		#partial switch c in e.derived_expr {
		case ^ast.Type_Cast:
			container_invalidation_expr(s, c.expr)
		case ^ast.Auto_Cast:
			container_invalidation_expr(s, c.expr)
		}
	case ^ast.Call_Expr:
		container_invalidation_call(s, n)
	case ^ast.Or_Return_Expr:
		container_invalidation_observe_expr(s, n.expr)
	case ^ast.Or_Else_Expr:
		container_invalidation_observe_expr(s, n.x)
		container_invalidation_observe_expr(s, n.y)
	case ^ast.Or_Branch_Expr:
		container_invalidation_observe_expr(s, n.expr)
	case ^ast.Comp_Lit:
		for elem in n.elems {
			container_invalidation_expr(s, elem)
		}
	case ^ast.Field_Value:
		container_invalidation_expr(s, n.value)
	case ^ast.Proc_Lit:
		container_invalidation_open_nested(s, n)
	case ^ast.Ternary_If_Expr:
		container_invalidation_expr(s, n.cond)
		container_invalidation_expr(s, n.x)
		container_invalidation_expr(s, n.y)
	}
}

@(private = "file")
container_invalidation_observe_expr :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) {
	saved := s.observe
	s.observe = true
	container_invalidation_expr(s, e)
	s.observe = saved
}

@(private = "file")
container_invalidation_call :: proc(s: ^Container_Invalidation_State, n: ^ast.Call_Expr) {
	container_invalidation_expr(s, n.expr)
	saved := s.observe
	s.observe = true
	for arg in n.args {
		container_invalidation_expr(s, arg)
	}
	s.observe = saved
	if s.halt != .None {
		return
	}
	name := container_invalidation_ident(n.expr)
	if name == "" || container_invalidation_shadowed(s, name) {
		container_invalidation_drop_addressed(s)
		return
	}
	if container_invalidation_is_growth(name) {
		// A bound result can be the failure path, where the old pointer
		// is still valid. This pass does not track that branch.
		if saved {
			return
		}
		container_invalidation_grow(s, n, name)
		return
	}
	if container_invalidation_is_len_op(name) {
		container_invalidation_len_op(s, n, name)
		return
	}
	if name == "raw_data" && len(n.args) >= 1 {
		container_invalidation_use_storage_expr(s, container_invalidation_value_arg(n.args[0]), n.pos.line)
		return
	}
	// Not a known growth or length builtin. The callee may store through
	// a pointer to a borrow variable passed as `&p`.
	container_invalidation_drop_addressed(s)
}

@(private = "file")
container_invalidation_open_nested :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Proc_Lit,
) {
	if s.file_base == nil || n.body == nil {
		return
	}
	// The nested procedure sees outer shadows and types. It does not see
	// outer locals, so a captured append is not inlined into the caller.
	nested := container_invalidation_clone(s.file_base)
	for name, count in s.shadow {
		nested.shadow[name] = count
	}
	for name, typ in s.types {
		nested.types[name] = typ
	}
	for name, num in s.consts {
		nested.consts[name] = num
	}
	container_invalidation_proc(&nested, n)
}

@(private = "file")
container_invalidation_grow :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Call_Expr,
	name: string,
) {
	name := name
	header_name, header, ok := container_invalidation_growth_header(s, n)
	if !ok {
		return
	}
	touched := s.storages[header.storage]
	touched.touch = n.pos.line
	touched.touch_op = name
	s.storages[header.storage] = touched
	info := touched
	if header.epoch != info.epoch {
		// The call reads this header's data pointer. A stale copy is a use.
		container_invalidation_report(s, header_name, header_name, info.died_op, n.pos.line, info.died, n.pos.line)
	}
	if info.elem_zero && (name == "append" || name == "non_zero_append" || name == "append_nothing") {
		added, added_known := container_invalidation_delta(s, n, name, false)
		if added_known {
			container_invalidation_note_len(s, header_name, added, true)
		} else {
			container_invalidation_forget_len(s, header_name)
		}
		return
	}
	delta, delta_known := container_invalidation_delta(s, n, name, info.elem_byte)
	moves := container_invalidation_moves(s, header, name, n, delta, delta_known)
	if moves || (s.repeating && delta_known && delta > 0 && !info.elem_zero) {
		container_invalidation_move(s, header_name, n.pos.line, name)
		header = s.headers[header_name]
	}
	switch name {
	case "append", "non_zero_append", "append_nothing", "inject_at":
		if delta_known {
			container_invalidation_note_len(s, header_name, delta, true)
		} else {
			container_invalidation_forget_len(s, header_name)
		}
	case "reserve", "non_zero_reserve":
		if num, known := container_invalidation_int(s, container_invalidation_arg(n, 1, "capacity")); known {
			container_invalidation_note_cap(s, header_name, num)
		} else if moves {
			container_invalidation_forget_cap(s, header_name)
		}
	case "resize", "non_zero_resize":
		if num, known := container_invalidation_int(s, container_invalidation_arg(n, 1, "length")); known {
			container_invalidation_set_len(s, header_name, num)
			container_invalidation_note_cap(s, header_name, num)
		} else {
			container_invalidation_forget_len(s, header_name)
			container_invalidation_forget_cap(s, header_name)
		}
	}
}

@(private = "file")
container_invalidation_len_op :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Call_Expr,
	name: string,
) {
	name := name
	header_name, header, ok := container_invalidation_growth_header(s, n)
	if !ok {
		return
	}
	if header.epoch != s.storages[header.storage].epoch {
		container_invalidation_forget_len(s, header_name)
		return
	}
	switch name {
	case "clear":
		container_invalidation_set_len(s, header_name, 0)
	case "pop", "pop_safe", "pop_front", "pop_front_safe", "ordered_remove", "unordered_remove":
		if header.len_exact && header.len > 0 {
			container_invalidation_set_len(s, header_name, header.len - 1)
		}
	case "remove_range":
		container_invalidation_forget_len(s, header_name)
	}
}

@(private = "file")
container_invalidation_mark_address :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> bool {
	id := container_invalidation_ident(e)
	if id == "" {
		return false
	}
	s.addressed[id] = true
	return true
}

@(private = "file")
container_invalidation_drop_addressed :: proc(
	s: ^Container_Invalidation_State,
	allocator := context.temp_allocator,
) {
	context.temp_allocator = allocator
	names := make([dynamic]string, context.temp_allocator)
	for name, taken in s.addressed {
		if taken {
			append(&names, name)
		}
	}
	for name in names {
		delete_key(&s.borrows, name)
	}
}

@(private = "file")
container_invalidation_use_borrow :: proc(s: ^Container_Invalidation_State, name: string, line: int) {
	borrow, ok := s.borrows[name]
	if !ok || borrow.storage < 0 || borrow.storage >= len(s.storages) {
		return
	}
	st := s.storages[borrow.storage]
	if borrow.epoch == st.epoch {
		return
	}
	died := borrow.died if borrow.died != 0 else st.died
	op := borrow.died_op if borrow.died_op != "" else st.died_op
	array := borrow.array
	if array == "" {
		array = container_invalidation_header_name(s, borrow.storage)
	}
	container_invalidation_report(s, name, array, op, line, died, borrow.line)
}

@(private = "file")
container_invalidation_use_storage_expr :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
	line: int,
) {
	e := e
	storage, ok := container_invalidation_storage_of_expr(s, e)
	if !ok || storage >= len(s.storages) {
		return
	}
	name := container_invalidation_ident(container_invalidation_skip_deref(s, container_invalidation_unparen(e)))
	header, is_header := s.headers[name]
	if alias, is_alias := s.aliases[name]; is_alias {
		header, is_header = s.headers[alias]
		name = alias
	}
	if !is_header || header.storage != storage || header.epoch == s.storages[storage].epoch {
		return
	}
	st := s.storages[storage]
	container_invalidation_report(s, name, name, st.died_op, line, st.died, line)
}

@(private = "file")
container_invalidation_write_target :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return
	}
	#partial switch n in e.derived_expr {
	case ^ast.Ident:
	case ^ast.Deref_Expr:
		container_invalidation_expr(s, n.expr)
		container_invalidation_use_storage_expr(s, n.expr, e.pos.line)
		// `q^ = ...` may store into every borrow whose address was taken.
		container_invalidation_drop_addressed(s)
	case ^ast.Index_Expr:
		container_invalidation_expr(s, n.expr)
		container_invalidation_expr(s, n.index)
		container_invalidation_use_storage_expr(s, n.expr, e.pos.line)
	case ^ast.Selector_Expr:
		container_invalidation_write_target(s, n.expr)
	case ^ast.Paren_Expr:
		container_invalidation_write_target(s, n.expr)
	case:
		container_invalidation_expr(s, e)
	}
}

@(private = "file")
container_invalidation_loop_reset :: proc(
	s: ^Container_Invalidation_State,
	body: ^ast.Stmt,
	entry: [dynamic]Container_Invalidation_Len_Snap,
	must: bool,
	trips: int,
	trips_known: bool,
) {
	// One iteration shows the net length change, including a clear or pop
	// that runs before the append. Further iterations repeat that net.
	stay := container_invalidation_clone(s)
	working := container_invalidation_clone(s)
	container_invalidation_stmt(&working, body, nil)
	if working.halt == .Break {
		working.halt = .None
	}
	if working.halt != .Return && !(trips_known && trips <= 1) {
		container_invalidation_project(&working, entry, trips, trips_known)
	}
	if must {
		container_invalidation_replace(s, &working)
		return
	}
	container_invalidation_join(s, &stay, &working)
}

@(private = "file")
container_invalidation_scan_stmt :: proc(
	s: ^Container_Invalidation_State,
	stmt: ^ast.Stmt,
) -> Container_Invalidation_Scan {
	scan := container_invalidation_scan_new()
	container_invalidation_scan_one(s, stmt, &scan)
	return scan
}

@(private = "file")
container_invalidation_scan_one :: proc(
	s: ^Container_Invalidation_State,
	stmt: ^ast.Stmt,
	scan: ^Container_Invalidation_Scan,
) {
	if stmt == nil || !scan.ok {
		return
	}
	#partial switch n in stmt.derived_stmt {
	case ^ast.Block_Stmt:
		container_invalidation_scan_list(s, n.stmts, scan)
	case ^ast.Expr_Stmt:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Assign_Stmt:
		for rhs in n.rhs {
			container_invalidation_scan_observed(s, rhs, scan)
		}
	case ^ast.Value_Decl:
		for value in n.values {
			container_invalidation_scan_observed(s, value, scan)
		}
	case ^ast.If_Stmt:
		container_invalidation_scan_if(s, n, scan)
	case ^ast.When_Stmt:
		container_invalidation_scan_when(s, n, scan)
	case ^ast.Switch_Stmt:
		container_invalidation_scan_one(s, n.init, scan)
		container_invalidation_scan_observed(s, n.cond, scan)
		container_invalidation_scan_cases(s, n.body, scan)
	case ^ast.Type_Switch_Stmt:
		container_invalidation_scan_one(s, n.tag, scan)
		container_invalidation_scan_expr(s, n.expr, scan)
		container_invalidation_scan_cases(s, n.body, scan)
	case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Inline_Range_Stmt:
		// A nested loop's trip count is not the outer count. Give up the proof.
		scan.ok = false
	case ^ast.Return_Stmt, ^ast.Branch_Stmt, ^ast.Defer_Stmt,
	     ^ast.Empty_Stmt, ^ast.Bad_Stmt, ^ast.Bad_Decl, ^ast.Using_Stmt, ^ast.Tag_Stmt:
	case:
		// An unknown statement can hide growth. The safe-loop proof stops.
		// The walk does not zero a capacity it already proved.
		scan.ok = false
	}
}

@(private = "file")
container_invalidation_scan_if :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.If_Stmt,
	scan: ^Container_Invalidation_Scan,
) {
	container_invalidation_scan_one(s, n.init, scan)
	container_invalidation_scan_observed(s, n.cond, scan)
	if !scan.ok {
		return
	}
	cond := container_invalidation_bool(s, n.cond)
	if cond == .True {
		container_invalidation_scan_one(s, n.body, scan)
		return
	}
	if cond == .False {
		container_invalidation_scan_one(s, n.else_stmt, scan)
		return
	}
	then := container_invalidation_scan_stmt(s, n.body)
	els := container_invalidation_scan_new()
	if n.else_stmt != nil {
		els = container_invalidation_scan_stmt(s, n.else_stmt)
	}
	if !then.ok || !els.ok {
		scan.ok = false
		return
	}
	merged := container_invalidation_scan_max(then, els)
	container_invalidation_scan_add(scan, merged)
	scan.exact = false
}

@(private = "file")
container_invalidation_scan_when :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.When_Stmt,
	scan: ^Container_Invalidation_Scan,
) {
	// A non-literal when is not merged outward. Its growth is inference.
	cond := container_invalidation_bool(s, n.cond)
	if cond == .True {
		container_invalidation_scan_one(s, n.body, scan)
	} else if cond == .False {
		container_invalidation_scan_one(s, n.else_stmt, scan)
	}
}

@(private = "file")
container_invalidation_scan_cases :: proc(
	s: ^Container_Invalidation_State,
	body: ^ast.Stmt,
	scan: ^Container_Invalidation_Scan,
) {
	if body == nil || !scan.ok {
		return
	}
	block, ok := body.derived_stmt.(^ast.Block_Stmt)
	if !ok {
		scan.ok = false
		return
	}
	saw_default := false
	merged := container_invalidation_scan_new()
	first := true
	for stmt in block.stmts {
		clause, is_case := stmt.derived_stmt.(^ast.Case_Clause)
		if !is_case {
			continue
		}
		if len(clause.list) == 0 {
			saw_default = true
		}
		arm := container_invalidation_scan_new()
		container_invalidation_scan_list(s, clause.body, &arm)
		if !arm.ok {
			scan.ok = false
			return
		}
		if first {
			merged = arm
			first = false
		} else {
			merged = container_invalidation_scan_max(merged, arm)
		}
	}
	if first {
		return
	}
	if !saw_default {
		merged = container_invalidation_scan_max(merged, container_invalidation_scan_new())
	}
	container_invalidation_scan_add(scan, merged)
	scan.exact = false
}

@(private = "file")
container_invalidation_scan_list :: proc(
	s: ^Container_Invalidation_State,
	stmts: []^ast.Stmt,
	scan: ^Container_Invalidation_Scan,
) {
	for stmt in stmts {
		#partial switch n in stmt.derived_stmt {
		case ^ast.Return_Stmt:
			return
		case ^ast.Branch_Stmt:
			if n.tok.kind == .Break || n.tok.kind == .Continue {
				return
			}
		}
		container_invalidation_scan_one(s, stmt, scan)
		if !scan.ok {
			return
		}
	}
}

@(private = "file")
container_invalidation_scan_expr :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
	scan: ^Container_Invalidation_Scan,
) {
	if e == nil || !scan.ok {
		return
	}
	#partial switch n in e.derived_expr {
	case ^ast.Call_Expr:
		container_invalidation_scan_call(s, n, scan)
	case ^ast.Paren_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Selector_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Unary_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Binary_Expr:
		container_invalidation_scan_expr(s, n.left, scan)
		container_invalidation_scan_expr(s, n.right, scan)
	case ^ast.Index_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
		container_invalidation_scan_expr(s, n.index, scan)
	case ^ast.Slice_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
		container_invalidation_scan_expr(s, n.low, scan)
		container_invalidation_scan_expr(s, n.high, scan)
	case ^ast.Deref_Expr:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Type_Cast:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Auto_Cast:
		container_invalidation_scan_expr(s, n.expr, scan)
	case ^ast.Comp_Lit:
		for elem in n.elems {
			container_invalidation_scan_expr(s, elem, scan)
		}
	case ^ast.Field_Value:
		container_invalidation_scan_expr(s, n.value, scan)
	case ^ast.Or_Return_Expr:
		container_invalidation_scan_observed(s, n.expr, scan)
	case ^ast.Or_Else_Expr:
		container_invalidation_scan_observed(s, n.x, scan)
		container_invalidation_scan_observed(s, n.y, scan)
	case ^ast.Or_Branch_Expr:
		container_invalidation_scan_observed(s, n.expr, scan)
	case ^ast.Ternary_If_Expr:
		container_invalidation_scan_expr(s, n.cond, scan)
		container_invalidation_scan_expr(s, n.x, scan)
		container_invalidation_scan_expr(s, n.y, scan)
	case ^ast.Proc_Lit:
		// A nested procedure is not inlined into this loop.
	}
}

@(private = "file")
container_invalidation_scan_observed :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
	scan: ^Container_Invalidation_Scan,
) {
	saved := s.observe
	s.observe = true
	defer s.observe = saved
	container_invalidation_scan_expr(s, e, scan)
}

@(private = "file")
container_invalidation_scan_call :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Call_Expr,
	scan: ^Container_Invalidation_Scan,
	allocator := context.temp_allocator,
) {
	context.temp_allocator = allocator
	saved := s.observe
	s.observe = true
	for arg in n.args {
		container_invalidation_scan_expr(s, arg, scan)
	}
	s.observe = saved
	container_invalidation_scan_expr(s, n.expr, scan)
	if !scan.ok || saved {
		return
	}
	name := container_invalidation_ident(n.expr)
	if name == "" || container_invalidation_shadowed(s, name) {
		return
	}
	if container_invalidation_is_len_op(name) {
		if _, _, found := container_invalidation_growth_header(s, n); found {
			scan.resets = true
		}
		return
	}
	if !container_invalidation_is_growth(name) {
		return
	}
	_, header, ok := container_invalidation_growth_header(s, n)
	if !ok || header.storage < 0 || header.storage >= len(s.storages) {
		return
	}
	st := s.storages[header.storage]
	delta, known := container_invalidation_delta(s, n, name, st.elem_byte)
	// reserve and resize compare against capacity, which clear does not
	// restore. append's length check has to see a clear that runs first,
	// so that proof is the simulated iteration, not this entry length.
	if name == "reserve" || name == "non_zero_reserve" || name == "resize" || name == "non_zero_resize" {
		if container_invalidation_moves(s, header, name, n, delta, known) {
			scan.ok = false
		}
		return
	}
	if !known {
		scan.ok = false
		return
	}
	extra := delta
	if name == "inject_at" {
		index, index_known := container_invalidation_int(s, container_invalidation_arg(n, 1, "index"))
		if index_known && header.len_exact && index > header.len {
			extra = index - header.len + delta
		} else if !index_known {
			scan.ok = false
			return
		}
	}
	if extra <= 0 {
		return
	}
	if scan.added == nil {
		scan.added = make(map[int]int, context.temp_allocator)
	}
	scan.added[header.storage] += extra
}
