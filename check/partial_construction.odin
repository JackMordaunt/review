package check

// A partial construction leak is a heap block this procedure acquired and
// still owns when a later failure returns. The acquisition has to be a
// builtin new or make with an explicit runtime.heap_allocator or
// os.heap_allocator argument, and the failure has to be or_return or a
// check of a later call's success value. defer, a freeing call, a named
// result the return hands back, and a write through a parameter all drop
// the proof. Anything less direct is left to odin-partial-construction-inferred.

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:strconv"
import "core:strings"

import "../finding"

@(private = "file")
Partial_Kind :: enum {
	Pointer,
	Container,
}

@(private = "file")
Partial_Meta :: struct {
	call:      int,
	line:      int,
	binding:   string,
	via:       string,
	allocator: string,
	kind:      Partial_Kind,
}

@(private = "file")
Partial_Alias :: struct {
	name:   string,
	live:   int,
	result: bool,
	param:  bool,
}

@(private = "file")
Partial_Flag :: struct {
	name:    string,
	boolean: bool,
	nilable: bool,
}

@(private = "file")
Partial_Scope :: struct {
	aliases: [dynamic]Partial_Alias,
	hidden:  [dynamic]string,
	flags:   [dynamic]Partial_Flag,
	defers:  [dynamic]^ast.Stmt,
}

@(private = "file")
Partial_Path :: struct {
	scopes:   [dynamic]Partial_Scope,
	born:     []bool,
	freed:    []bool,
	poisoned: []bool,
}

@(private = "file")
Partial_File :: struct {
	path:     string,
	src:      string,
	added:    map[int]bool,
	aliases:  map[string]^ast.Expr,
	imports:  map[string]string,
	names:    map[string]bool,
	out:      ^[dynamic]finding.Finding,
	alloc:    runtime.Allocator,
}

@(private = "file")
Partial_Analyser :: struct {
	file:     ^Partial_File,
	metas:    [dynamic]Partial_Meta,
	reported: []bool,
	named:    [dynamic]string,
	by_call:  map[int]int,
}

@(private = "file")
Partial_Mention :: struct {
	value: bool,
	addr:  bool,
}

check_partial_construction :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	keep := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = keep
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
		checked := Partial_File {
			path    = path,
			src     = string(src),
			added   = make(map[int]bool),
			aliases = make(map[string]^ast.Expr),
			imports = make(map[string]string),
			names   = make(map[string]bool),
			out     = out,
			alloc   = keep,
		}
		for line in s.c.added[path] {
			checked.added[line.line] = true
		}
		partial_construction_file(&checked, file)
	}
}

@(private = "file")
partial_construction_file :: proc(f: ^Partial_File, file: ^ast.File) {
	for decl in file.decls {
		#partial switch n in decl.derived_stmt {
		case ^ast.Import_Decl:
			name, path, ok := partial_construction_import(n)
			if !ok {
				continue
			}
			f.imports[name] = path
			f.names[name] = true
		case ^ast.Value_Decl:
			if len(n.names) == 1 && len(n.values) == 1 && !n.is_mutable {
				if ident, is_ident := n.names[0].derived_expr.(^ast.Ident); is_ident {
					f.aliases[ident.name] = n.values[0]
				}
			}
			for name in n.names {
				if ident, is_ident := name.derived_expr.(^ast.Ident); is_ident {
					f.names[ident.name] = true
				}
			}
		}
	}
	procs: [dynamic]^ast.Proc_Lit
	v := ast.Visitor {
		visit = partial_construction_collect,
		data  = &procs,
	}
	for decl in file.decls {
		ast.walk(&v, decl)
	}
	for proc_lit in procs {
		partial_construction_proc(f, proc_lit)
	}
}

@(private = "file")
partial_construction_collect :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	procs := (^[dynamic]^ast.Proc_Lit)(v.data)
	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		if n.body != nil {
			append(procs, n)
		}
	}
	return v
}

@(private = "file")
partial_construction_import :: proc(n: ^ast.Import_Decl) -> (name, path: string, ok: bool) {
	path = strings.trim(n.relpath.text, "\"")
	if n.name.text == "_" {
		return
	}
	name = n.name.text
	if name == "" {
		name = path
		if i := strings.last_index_any(name, ":/"); i >= 0 {
			name = name[i + 1:]
		}
	}
	ok = name != ""
	return
}

@(private = "file")
partial_construction_proc :: proc(f: ^Partial_File, proc_lit: ^ast.Proc_Lit) {
	a := Partial_Analyser {
		file    = f,
		by_call = make(map[int]int),
	}
	partial_construction_prescan(&a, proc_lit.body)
	if len(a.metas) == 0 {
		return
	}
	a.reported = make([]bool, len(a.metas))
	if proc_lit.type != nil && proc_lit.type.results != nil {
		for field in proc_lit.type.results.list {
			for name in field.names {
				if ident, is_ident := name.derived_expr.(^ast.Ident); is_ident && ident.name != "_" {
					append(&a.named, ident.name)
				}
			}
		}
	}
	path := Partial_Path {
		born     = make([]bool, len(a.metas)),
		freed    = make([]bool, len(a.metas)),
		poisoned = make([]bool, len(a.metas)),
	}
	partial_construction_push(&path)
	if proc_lit.type != nil && proc_lit.type.params != nil {
		for field in proc_lit.type.params.list {
			for name in field.names {
				if ident, is_ident := name.derived_expr.(^ast.Ident); is_ident && ident.name != "_" {
					partial_construction_hide(&path, ident.name, true)
				}
			}
		}
	}
	for name in a.named {
		partial_construction_note_result(&path, name)
	}
	// The body has its own scope; shadowing preserves the result bindings.
	partial_construction_push(&path)
	partial_construction_stmts(&a, &path, partial_construction_block_stmts(proc_lit.body), false)
}

@(private = "file")
partial_construction_note_result :: proc(path: ^Partial_Path, name: string) {
	scope := &path.scopes[0]
	append(&scope.aliases, Partial_Alias{name = name, live = -1, result = true})
}

@(private = "file")
partial_construction_prescan :: proc(a: ^Partial_Analyser, node: ^ast.Stmt) {
	if node == nil {
		return
	}
	#partial switch n in node.derived_stmt {
	case ^ast.Value_Decl:
		partial_construction_prescan_bind(a, n.values)
		for value in n.values {
			partial_construction_prescan_expr(a, value)
		}
	case ^ast.Assign_Stmt:
		partial_construction_prescan_bind(a, n.rhs)
		for value in n.rhs {
			partial_construction_prescan_expr(a, value)
		}
	case ^ast.Block_Stmt:
		for stmt in n.stmts {
			partial_construction_prescan(a, stmt)
		}
	case ^ast.If_Stmt:
		partial_construction_prescan(a, n.init)
		partial_construction_prescan_expr(a, n.cond)
		partial_construction_prescan(a, n.body)
		partial_construction_prescan(a, n.else_stmt)
	case ^ast.For_Stmt:
		partial_construction_prescan(a, n.init)
		partial_construction_prescan_expr(a, n.cond)
		partial_construction_prescan(a, n.post)
		partial_construction_prescan(a, n.body)
	case ^ast.Range_Stmt:
		partial_construction_prescan_expr(a, n.expr)
		partial_construction_prescan(a, n.body)
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		body: ^ast.Stmt
		#partial switch s in node.derived_stmt {
		case ^ast.Switch_Stmt:
			partial_construction_prescan(a, s.init)
			partial_construction_prescan_expr(a, s.cond)
			body = s.body
		case ^ast.Type_Switch_Stmt:
			partial_construction_prescan(a, s.tag)
			partial_construction_prescan_expr(a, s.expr)
			body = s.body
		}
		partial_construction_prescan(a, body)
	case ^ast.Defer_Stmt:
		partial_construction_prescan(a, n.stmt)
	case ^ast.Expr_Stmt:
		partial_construction_prescan_expr(a, n.expr)
	case ^ast.Return_Stmt:
		for result in n.results {
			partial_construction_prescan_expr(a, result)
		}
	}
}

@(private = "file")
partial_construction_prescan_expr :: proc(a: ^Partial_Analyser, expr: ^ast.Expr) {
	if expr == nil {
		return
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Proc_Lit:
		return
	case ^ast.Paren_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Or_Return_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Or_Else_Expr:
		partial_construction_prescan_expr(a, e.x)
		partial_construction_prescan_expr(a, e.y)
	case ^ast.Unary_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Binary_Expr:
		partial_construction_prescan_expr(a, e.left)
		partial_construction_prescan_expr(a, e.right)
	case ^ast.Selector_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Call_Expr:
		partial_construction_prescan_expr(a, e.expr)
		for arg in e.args {
			partial_construction_prescan_expr(a, arg)
		}
	case ^ast.Field_Value:
		partial_construction_prescan_expr(a, e.value)
	case ^ast.Comp_Lit:
		partial_construction_prescan_expr(a, e.type)
		for elem in e.elems {
			partial_construction_prescan_expr(a, elem)
		}
	case ^ast.Index_Expr:
		partial_construction_prescan_expr(a, e.expr)
		partial_construction_prescan_expr(a, e.index)
	case ^ast.Slice_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Deref_Expr:
		partial_construction_prescan_expr(a, e.expr)
	case ^ast.Ternary_If_Expr:
		partial_construction_prescan_expr(a, e.x)
		partial_construction_prescan_expr(a, e.y)
	}
}

@(private = "file")
partial_construction_prescan_bind :: proc(a: ^Partial_Analyser, values: []^ast.Expr) {
	if len(values) != 1 {
		return
	}
	call := partial_construction_call(partial_construction_strip(values[0]))
	if call == nil {
		return
	}
	if _, seen := a.by_call[call.pos.offset]; seen {
		return
	}
	meta, ok := partial_construction_acquisition(a, call)
	if !ok {
		return
	}
	a.by_call[call.pos.offset] = len(a.metas)
	append(&a.metas, meta)
}

@(private = "file")
partial_construction_strip :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	cur := expr
	for cur != nil {
		#partial switch e in cur.derived_expr {
		case ^ast.Paren_Expr:
			cur = e.expr
		case ^ast.Or_Return_Expr:
			cur = e.expr
		case:
			return cur
		}
	}
	return cur
}

@(private = "file")
partial_construction_call :: proc(expr: ^ast.Expr) -> ^ast.Call_Expr {
	if expr == nil {
		return nil
	}
	call, _ := expr.derived_expr.(^ast.Call_Expr)
	return call
}

@(private = "file")
partial_construction_acquisition :: proc(
	a: ^Partial_Analyser,
	call: ^ast.Call_Expr,
) -> (
	meta: Partial_Meta,
	ok: bool,
) {
	name := partial_construction_callee(call.expr)
	if name != "new" && name != "make" {
		return
	}
	if partial_construction_file_shadow(a.file, name) {
		return
	}
	heap, heap_ok := partial_construction_heap_args(a, call)
	if !heap_ok {
		return
	}
	if name == "new" {
		if len(call.args) == 0 || !partial_construction_nonzero(a.file, partial_construction_value(call.args[0]), 0) {
			return
		}
		meta = Partial_Meta{call.pos.offset, call.pos.line, "", "new", heap, .Pointer}
		ok = true
		return
	}
	if len(call.args) == 0 || !partial_construction_make_sized(a, call) {
		return
	}
	meta = Partial_Meta{call.pos.offset, call.pos.line, "", "make", heap, .Container}
	ok = true
	return
}

@(private = "file")
partial_construction_callee :: proc(expr: ^ast.Expr) -> string {
	if expr == nil {
		return ""
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Ident:
		return e.name
	case ^ast.Selector_Expr:
		if e.field != nil {
			return e.field.name
		}
	case ^ast.Paren_Expr:
		return partial_construction_callee(e.expr)
	}
	return ""
}

@(private = "file")
partial_construction_value :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	if expr == nil {
		return nil
	}
	if field, ok := expr.derived_expr.(^ast.Field_Value); ok {
		return field.value
	}
	return expr
}

@(private = "file")
partial_construction_field_name :: proc(expr: ^ast.Expr) -> string {
	field, ok := expr.derived_expr.(^ast.Field_Value)
	if !ok || field.field == nil {
		return ""
	}
	ident, is_ident := field.field.derived_expr.(^ast.Ident)
	if !is_ident {
		return ""
	}
	return ident.name
}

@(private = "file")
partial_construction_heap_args :: proc(a: ^Partial_Analyser, call: ^ast.Call_Expr) -> (label: string, ok: bool) {
	label = ""
	for arg in call.args {
		value := partial_construction_value(arg)
		got, is_heap := partial_construction_heap_call(a, value)
		if !is_heap {
			continue
		}
		if label != "" && label != got {
			return "", false
		}
		label = got
	}
	ok = label != ""
	return
}

@(private = "file")
partial_construction_heap_call :: proc(a: ^Partial_Analyser, expr: ^ast.Expr) -> (label: string, ok: bool) {
	call := partial_construction_call(partial_construction_strip(expr))
	if call == nil || len(call.args) != 0 {
		return
	}
	sel, is_sel := call.expr.derived_expr.(^ast.Selector_Expr)
	if !is_sel || sel.field == nil || sel.field.name != "heap_allocator" {
		return
	}
	pkg, is_pkg := sel.expr.derived_expr.(^ast.Ident)
	if !is_pkg {
		return
	}
	found := partial_construction_resolve_pkg(a.file, pkg.name)
	switch found {
	case "base:runtime":
		return "runtime.heap_allocator", true
	case "core:os":
		return "os.heap_allocator", true
	}
	return
}

@(private = "file")
partial_construction_resolve_pkg :: proc(f: ^Partial_File, name: string) -> string {
	if path, ok := f.imports[name]; ok {
		return path
	}
	if name == "runtime" && !f.names[name] {
		return "base:runtime"
	}
	return ""
}

@(private = "file")
partial_construction_file_shadow :: proc(f: ^Partial_File, name: string) -> bool {
	return f.names[name]
}

@(private = "file")
partial_construction_make_sized :: proc(a: ^Partial_Analyser, call: ^ast.Call_Expr) -> bool {
	type_expr := partial_construction_value(call.args[0])
	kind, elem, type_ok := partial_construction_make_type(a.file, type_expr, 0)
	if !type_ok {
		return false
	}
	ints: [dynamic]bool
	named_len, named_cap: int
	seen_len, seen_cap: bool
	for arg, i in call.args {
		if i == 0 && partial_construction_field_name(arg) == "" {
			continue
		}
		value := partial_construction_value(arg)
		field := partial_construction_field_name(arg)
		if _, heap := partial_construction_heap_call(a, value); heap || field == "allocator" || field == "loc" {
			continue
		}
		if _, directive := value.derived_expr.(^ast.Basic_Directive); directive {
			continue
		}
		positive := partial_construction_positive(value)
		switch field {
		case "len":
			named_len, seen_len = 1 if positive else 0, true
		case "cap", "capacity":
			named_cap, seen_cap = 1 if positive else 0, true
		case "alignment":
		case "":
			if !positive && !partial_construction_zero(value) {
				return false
			}
			append(&ints, positive)
		case:
			return false
		}
	}
	#partial switch kind {
	case .Slice, .Multi:
		if !partial_construction_nonzero(a.file, elem, 0) {
			return false
		}
		if seen_len {
			return named_len > 0
		}
		return len(ints) >= 1 && ints[0]
	case .Dynamic:
		if !partial_construction_nonzero(a.file, elem, 0) {
			return false
		}
		if seen_cap {
			return named_cap > 0
		}
		if seen_len {
			return named_len > 0
		}
		if len(ints) >= 2 {
			return ints[1]
		}
		return len(ints) == 1 && ints[0]
	case .Map:
		if seen_cap {
			return named_cap > 0
		}
		return len(ints) >= 1 && ints[0]
	}
	return false
}

@(private = "file")
Partial_Make :: enum {
	Slice,
	Dynamic,
	Map,
	Multi,
}

@(private = "file")
partial_construction_make_type :: proc(
	f: ^Partial_File,
	expr: ^ast.Expr,
	depth: int,
) -> (
	kind: Partial_Make,
	elem: ^ast.Expr,
	ok: bool,
) {
	if expr == nil || depth > 8 {
		return
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Paren_Expr:
		return partial_construction_make_type(f, e.expr, depth + 1)
	case ^ast.Helper_Type, ^ast.Distinct_Type:
		inner: ^ast.Expr
		#partial switch d in expr.derived_expr {
		case ^ast.Helper_Type:
			inner = d.type
		case ^ast.Distinct_Type:
			inner = d.type
		}
		return partial_construction_make_type(f, inner, depth + 1)
	case ^ast.Array_Type:
		if e.len != nil {
			return
		}
		return .Slice, e.elem, true
	case ^ast.Dynamic_Array_Type:
		return .Dynamic, e.elem, true
	case ^ast.Multi_Pointer_Type:
		return .Multi, e.elem, true
	case ^ast.Map_Type:
		return .Map, nil, true
	case ^ast.Ident:
		if next, found := f.aliases[e.name]; found {
			return partial_construction_make_type(f, next, depth + 1)
		}
	}
	return
}

@(private = "file")
partial_construction_positive :: proc(expr: ^ast.Expr) -> bool {
	lit, ok := expr.derived_expr.(^ast.Basic_Lit)
	if !ok || lit.tok.kind != .Integer {
		return false
	}
	return partial_construction_int(lit.tok.text) > 0
}

@(private = "file")
partial_construction_zero :: proc(expr: ^ast.Expr) -> bool {
	lit, ok := expr.derived_expr.(^ast.Basic_Lit)
	if !ok || lit.tok.kind != .Integer {
		return false
	}
	return partial_construction_int(lit.tok.text) == 0
}

// Unlike owning_copy_int, invalid literals return -1: zero is a separate
// capacity fact, so a failed parse must not become a zero-sized allocation.
@(private = "file")
partial_construction_int :: proc(text: string) -> int {
	clean, _ := strings.replace_all(text, "_", "", context.temp_allocator)
	base := 10
	digits := clean
	switch {
	case strings.has_prefix(clean, "0x") || strings.has_prefix(clean, "0X"):
		base, digits = 16, clean[2:]
	case strings.has_prefix(clean, "0o") || strings.has_prefix(clean, "0O"):
		base, digits = 8, clean[2:]
	case strings.has_prefix(clean, "0b") || strings.has_prefix(clean, "0B"):
		base, digits = 2, clean[2:]
	}
	n, ok := strconv.parse_int(digits, base)
	if !ok {
		return -1
	}
	return n
}

@(private = "file")
partial_construction_nonzero :: proc(f: ^Partial_File, expr: ^ast.Expr, depth: int) -> bool {
	if expr == nil || depth > 8 {
		return false
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Paren_Expr:
		return partial_construction_nonzero(f, e.expr, depth + 1)
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type:
		return true
	case ^ast.Array_Type:
		if e.len == nil {
			return true
		}
		return partial_construction_positive(e.len) && partial_construction_nonzero(f, e.elem, depth + 1)
	case ^ast.Dynamic_Array_Type, ^ast.Map_Type:
		return true
	case ^ast.Distinct_Type:
		return partial_construction_nonzero(f, e.type, depth + 1)
	case ^ast.Helper_Type:
		return partial_construction_nonzero(f, e.type, depth + 1)
	case ^ast.Struct_Type:
		if e.fields == nil {
			return false
		}
		for field in e.fields.list {
			if partial_construction_nonzero(f, field.type, depth + 1) {
				return true
			}
		}
		return false
	case ^ast.Ident:
		if partial_construction_builtin_nonzero(e.name) {
			return true
		}
		if next, found := f.aliases[e.name]; found {
			return partial_construction_nonzero(f, next, depth + 1)
		}
	}
	return false
}

@(private = "file")
partial_construction_builtin_nonzero :: proc(name: string) -> bool {
	switch name {
	case "int", "uint", "uintptr", "rawptr", "bool", "byte", "rune", "string", "cstring",
	     "f16", "f32", "f64", "complex32", "complex64", "complex128",
	     "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	     "typeid", "any":
		return true
	case:
		return false
	}
}

@(private = "file")
partial_construction_push :: proc(path: ^Partial_Path) {
	append(&path.scopes, Partial_Scope{})
}

@(private = "file")
partial_construction_pop :: proc(path: ^Partial_Path) {
	if len(path.scopes) == 0 {
		return
	}
	pop(&path.scopes)
}

@(private = "file")
partial_construction_hide :: proc(path: ^Partial_Path, name: string, param: bool) {
	scope := &path.scopes[len(path.scopes) - 1]
	append(&scope.hidden, name)
	if param {
		append(&scope.aliases, Partial_Alias{name = name, live = -1, param = true})
	}
}

@(private = "file")
partial_construction_top :: proc(path: ^Partial_Path) -> ^Partial_Scope {
	return &path.scopes[len(path.scopes) - 1]
}

@(private = "file")
partial_construction_bind_alias :: proc(path: ^Partial_Path, name: string, live: int, result: bool) {
	if name == "_" {
		return
	}
	scope := partial_construction_top(path)
	for &entry in scope.aliases {
		if entry.name == name {
			entry.live = live
			entry.result = result
			return
		}
	}
	append(&scope.aliases, Partial_Alias{name = name, live = live, result = result})
}

@(private = "file")
partial_construction_shadow :: proc(path: ^Partial_Path, name: string) {
	if name == "_" {
		return
	}
	scope := partial_construction_top(path)
	append(&scope.hidden, name)
	for &entry in scope.aliases {
		if entry.name == name {
			entry.live = -1
			entry.result = false
			entry.param = false
			return
		}
	}
}

@(private = "file")
partial_construction_declared :: proc(path: ^Partial_Path, name: string) -> bool {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		for entry in scope.hidden {
			if entry == name {
				return true
			}
		}
		for entry in scope.aliases {
			if entry.name == name {
				return true
			}
		}
		for entry in scope.flags {
			if entry.name == name {
				return true
			}
		}
	}
	return false
}

@(private = "file")
partial_construction_lookup :: proc(path: ^Partial_Path, name: string) -> (alias: Partial_Alias, ok: bool) {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		hidden := false
		for entry in scope.hidden {
			if entry == name {
				hidden = true
			}
		}
		for i := len(scope.aliases) - 1; i >= 0; i -= 1 {
			if scope.aliases[i].name == name {
				if scope.aliases[i].live < 0 {
					return scope.aliases[i], false
				}
				return scope.aliases[i], true
			}
		}
		if hidden {
			return {}, false
		}
	}
	return
}

@(private = "file")
partial_construction_param :: proc(path: ^Partial_Path, name: string) -> bool {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		for entry in scope.hidden {
			if entry == name {
				for alias in scope.aliases {
					if alias.name == name {
						return alias.param && alias.live < 0
					}
				}
				return false
			}
		}
		for alias in scope.aliases {
			if alias.name == name && alias.live >= 0 {
				return false
			}
		}
	}
	return false
}

@(private = "file")
partial_construction_flag :: proc(path: ^Partial_Path, name: string) -> (flag: Partial_Flag, ok: bool) {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		for i := len(scope.flags) - 1; i >= 0; i -= 1 {
			if scope.flags[i].name == name {
				return scope.flags[i], true
			}
		}
		if partial_construction_scope_binds(scope, name) {
			return {}, false
		}
	}
	return
}

@(private = "file")
partial_construction_scope_binds :: proc(scope: Partial_Scope, name: string) -> bool {
	for entry in scope.hidden {
		if entry == name {
			return true
		}
	}
	for entry in scope.aliases {
		if entry.name == name {
			return true
		}
	}
	for entry in scope.flags {
		if entry.name == name {
			return true
		}
	}
	return false
}

@(private = "file")
partial_construction_set_flag :: proc(path: ^Partial_Path, name: string, nilable: bool) {
	if name == "_" {
		return
	}
	append(&partial_construction_top(path).flags, Partial_Flag{name, true, nilable})
}

@(private = "file")
partial_construction_block_stmts :: proc(node: ^ast.Stmt) -> []^ast.Stmt {
	if node == nil {
		return nil
	}
	if block, ok := node.derived_stmt.(^ast.Block_Stmt); ok {
		return block.stmts
	}
	return nil
}

@(private = "file")
partial_construction_stmts :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	stmts: []^ast.Stmt,
	in_failure: bool,
) -> bool {
	for stmt in stmts {
		if !partial_construction_stmt(a, path, stmt, in_failure) {
			return false
		}
	}
	return true
}

@(private = "file")
partial_construction_stmt :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	stmt: ^ast.Stmt,
	in_failure: bool,
) -> bool {
	if stmt == nil {
		return true
	}
	#partial switch n in stmt.derived_stmt {
	case ^ast.Value_Decl:
		for value in n.values {
			partial_construction_effects(a, path, value, true)
		}
		if n.is_mutable {
			partial_construction_bind(a, path, n.names, n.values, true)
		}
	case ^ast.Assign_Stmt:
		for value in n.rhs {
			partial_construction_effects(a, path, value, true)
		}
		if n.op.kind == .Eq {
			partial_construction_assign(a, path, n.lhs, n.rhs)
		}
	case ^ast.Expr_Stmt:
		partial_construction_effects(a, path, n.expr, true)
	case ^ast.Block_Stmt:
		partial_construction_push(path)
		falls := partial_construction_stmts(a, path, n.stmts, in_failure)
		if falls {
			partial_construction_run_defers(a, path, len(path.scopes) - 1)
		}
		partial_construction_pop(path)
		return falls
	case ^ast.Defer_Stmt:
		append(&partial_construction_top(path).defers, n.stmt)
	case ^ast.Return_Stmt:
		if in_failure {
			partial_construction_judge(a, path, n.results, n.pos.line, false)
		}
		return false
	case ^ast.If_Stmt:
		return partial_construction_if(a, path, n, in_failure)
	case ^ast.For_Stmt:
		if n.init != nil {
			partial_construction_stmt(a, path, n.init, in_failure)
		}
		partial_construction_effects(a, path, n.cond, true)
		clone := partial_construction_clone(path)
		partial_construction_stmt(a, &clone, n.body, in_failure)
		if n.post != nil {
			partial_construction_stmt(a, &clone, n.post, in_failure)
		}
		partial_construction_poison_diff(path, &clone)
	case ^ast.Range_Stmt:
		partial_construction_effects(a, path, n.expr, true)
		clone := partial_construction_clone(path)
		partial_construction_push(&clone)
		for val in n.vals {
			if ident, is_ident := val.derived_expr.(^ast.Ident); is_ident {
				partial_construction_shadow(&clone, ident.name)
			}
		}
		partial_construction_stmt(a, &clone, n.body, in_failure)
		partial_construction_pop(&clone)
		partial_construction_poison_diff(path, &clone)
	case ^ast.Switch_Stmt:
		if n.init != nil {
			partial_construction_stmt(a, path, n.init, in_failure)
		}
		partial_construction_effects(a, path, n.cond, true)
		partial_construction_cases(a, path, n.body, in_failure)
	case ^ast.Type_Switch_Stmt:
		if n.tag != nil {
			partial_construction_stmt(a, path, n.tag, in_failure)
		}
		partial_construction_effects(a, path, n.expr, true)
		partial_construction_cases(a, path, n.body, in_failure)
	}
	return true
}

@(private = "file")
partial_construction_cases :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	body: ^ast.Stmt,
	in_failure: bool,
) {
	block, ok := body.derived_stmt.(^ast.Block_Stmt)
	if !ok {
		return
	}
	for stmt in block.stmts {
		clause, is_clause := stmt.derived_stmt.(^ast.Case_Clause)
		if !is_clause {
			continue
		}
		clone := partial_construction_clone(path)
		partial_construction_stmts(a, &clone, clause.body, in_failure)
		partial_construction_poison_diff(path, &clone)
	}
}

@(private = "file")
partial_construction_if :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	n: ^ast.If_Stmt,
	in_failure: bool,
) -> bool {
	partial_construction_push(path)
	if n.init != nil {
		partial_construction_stmt(a, path, n.init, in_failure)
	}
	partial_construction_effects(a, path, n.cond, true)
	enter := partial_construction_clone(path)
	then_fails, else_fails := partial_construction_failure(a, path, n.cond)
	then_path := partial_construction_clone(path)
	else_path := partial_construction_clone(path)
	then_fall := partial_construction_stmt(a, &then_path, n.body, in_failure || then_fails)
	else_fall := true
	if n.else_stmt != nil {
		else_fall = partial_construction_stmt(a, &else_path, n.else_stmt, in_failure || else_fails)
	}
	depth := len(path.scopes) - 1
	if then_fall {
		partial_construction_run_defers(a, &then_path, depth)
		partial_construction_pop(&then_path)
	}
	if else_fall {
		partial_construction_run_defers(a, &else_path, depth)
		partial_construction_pop(&else_path)
	}
	partial_construction_join(path, &enter, &then_path, then_fall, &else_path, else_fall)
	return then_fall || else_fall
}

@(private = "file")
partial_construction_join :: proc(
	path: ^Partial_Path,
	base: ^Partial_Path,
	then_path: ^Partial_Path,
	then_fall: bool,
	else_path: ^Partial_Path,
	else_fall: bool,
) {
	if then_fall && !else_fall {
		partial_construction_adopt(path, then_path)
		return
	}
	if else_fall && !then_fall {
		partial_construction_adopt(path, else_path)
		return
	}
	if !then_fall && !else_fall {
		partial_construction_adopt(path, base)
		partial_construction_pop(path)
		return
	}
	// Keep assignments the condition and init made to outer names, and
	// drop names declared in the if itself.
	partial_construction_adopt(path, base)
	partial_construction_pop(path)
	for i in 0 ..< len(path.born) {
		if then_path.born[i] != else_path.born[i] ||
		   then_path.freed[i] != else_path.freed[i] ||
		   then_path.poisoned[i] ||
		   else_path.poisoned[i] ||
		   !partial_construction_same_aliases(then_path, else_path, i) {
			path.poisoned[i] = true
			continue
		}
		path.born[i] = then_path.born[i]
		path.freed[i] = then_path.freed[i]
		if !partial_construction_same_aliases(then_path, base, i) {
			path.poisoned[i] = true
		}
	}
}

@(private = "file")
partial_construction_adopt :: proc(dst, src: ^Partial_Path) {
	dst.scopes = src.scopes
	dst.born = src.born
	dst.freed = src.freed
	dst.poisoned = src.poisoned
}

@(private = "file")
partial_construction_same_aliases :: proc(a, b: ^Partial_Path, live: int) -> bool {
	left := partial_construction_visible(a, live)
	right := partial_construction_visible(b, live)
	if len(left) != len(right) {
		return false
	}
	for entry in left {
		found := false
		for other in right {
			if other.name == entry.name && other.result == entry.result {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

@(private = "file")
partial_construction_visible :: proc(path: ^Partial_Path, live: int) -> []Partial_Alias {
	out := make([dynamic]Partial_Alias, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		for i := len(scope.aliases) - 1; i >= 0; i -= 1 {
			entry := scope.aliases[i]
			if seen[entry.name] {
				continue
			}
			seen[entry.name] = true
			if entry.live == live {
				append(&out, entry)
			}
		}
		for entry in scope.hidden {
			seen[entry] = true
		}
	}
	return out[:]
}

@(private = "file")
partial_construction_bind :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	names: []^ast.Expr,
	values: []^ast.Expr,
	declare: bool,
) {
	if len(values) == 1 {
		call := partial_construction_call(partial_construction_strip(values[0]))
		if call != nil {
			if id, found := a.by_call[call.pos.offset]; found {
				if !partial_construction_call_clear(a, path, call) {
					return
				}
				if len(names) >= 1 {
					if ident, is_ident := names[0].derived_expr.(^ast.Ident); is_ident {
						kept := partial_construction_is_result(path, ident.name)
						if declare {
							partial_construction_shadow(path, ident.name)
							partial_construction_bind_alias(path, ident.name, id, false)
						} else {
							partial_construction_retarget(path, ident.name, id)
							if kept {
								partial_construction_mark_result(path, ident.name)
							}
						}
						path.born[id] = true
						a.metas[id].binding = ident.name
					}
				}
				for name, index in names {
					if index == 0 {
						continue
					}
					if ident, is_ident := name.derived_expr.(^ast.Ident); is_ident {
						partial_construction_shadow(path, ident.name)
					}
				}
				return
			}
		}
	}
	refers := -1
	if len(values) == 1 {
		refers = partial_construction_expr_live(path, values[0])
	}
	for name, index in names {
		ident, is_ident := name.derived_expr.(^ast.Ident)
		if !is_ident || ident.name == "_" {
			continue
		}
		if declare {
			if refers >= 0 && (len(values) == 1 || index == 0) {
				partial_construction_shadow(path, ident.name)
				partial_construction_bind_alias(path, ident.name, refers, false)
			} else {
				partial_construction_shadow(path, ident.name)
			}
		} else if refers >= 0 && index == 0 {
			partial_construction_retarget(path, ident.name, refers)
		}
		if len(values) == 1 &&
		   partial_construction_call(partial_construction_strip(values[0])) != nil &&
		   index == len(names) - 1 {
			partial_construction_set_flag(path, ident.name, len(names) >= 2)
		}
	}
}

@(private = "file")
partial_construction_assign :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	lhs, rhs: []^ast.Expr,
) {
	if len(rhs) == 1 {
		call := partial_construction_call(partial_construction_strip(rhs[0]))
		if call != nil {
			if id, found := a.by_call[call.pos.offset]; found && len(lhs) >= 1 {
				if ident, is_ident := lhs[0].derived_expr.(^ast.Ident); is_ident {
					if !partial_construction_call_clear(a, path, call) {
						return
					}
					result := partial_construction_is_result(path, ident.name)
					partial_construction_retarget(path, ident.name, id)
					if result {
						partial_construction_mark_result(path, ident.name)
					}
					path.born[id] = true
					a.metas[id].binding = ident.name
					return
				}
				partial_construction_store_through(path, lhs[0], id)
				path.born[id] = true
				return
			}
		}
	}
	lives := make([dynamic]int, context.temp_allocator)
	if len(rhs) == 1 {
		partial_construction_expr_lives(path, rhs[0], &lives)
	} else {
		for value in rhs {
			partial_construction_expr_lives(path, value, &lives)
		}
	}
	for side in lhs {
		if ident, is_ident := side.derived_expr.(^ast.Ident); is_ident {
			if len(lives) == 1 {
				result := partial_construction_is_result(path, ident.name)
				partial_construction_retarget(path, ident.name, lives[0])
				if result {
					partial_construction_mark_result(path, ident.name)
				}
			} else if len(lives) == 0 {
				partial_construction_retarget(path, ident.name, -1)
			} else {
				for live in lives {
					path.poisoned[live] = true
				}
			}
			continue
		}
		if partial_construction_root_param(path, side) {
			for live in lives {
				path.poisoned[live] = true
			}
			continue
		}
		root := partial_construction_root(side)
		if root != "" && len(lives) == 1 {
			partial_construction_assign_name(path, root, lives[0])
		} else {
			for live in lives {
				path.poisoned[live] = true
			}
		}
	}
}

@(private = "file")
partial_construction_store_through :: proc(path: ^Partial_Path, lhs: ^ast.Expr, live: int) {
	if partial_construction_root_param(path, lhs) || partial_construction_root(lhs) == "" {
		path.poisoned[live] = true
		return
	}
	partial_construction_assign_name(path, partial_construction_root(lhs), live)
}

@(private = "file")
partial_construction_root_param :: proc(path: ^Partial_Path, expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	if _, is_ident := expr.derived_expr.(^ast.Ident); is_ident {
		return false
	}
	root := partial_construction_root(expr)
	if root == "" {
		return false
	}
	return partial_construction_param(path, root)
}

@(private = "file")
partial_construction_root :: proc(expr: ^ast.Expr) -> string {
	cur := expr
	for cur != nil {
		#partial switch e in cur.derived_expr {
		case ^ast.Ident:
			return e.name
		case ^ast.Paren_Expr:
			cur = e.expr
		case ^ast.Selector_Expr:
			cur = e.expr
		case ^ast.Index_Expr:
			cur = e.expr
		case ^ast.Deref_Expr:
			cur = e.expr
		case ^ast.Slice_Expr:
			cur = e.expr
		case ^ast.Unary_Expr:
			if e.op.kind == .And {
				cur = e.expr
				continue
			}
			return ""
		case:
			return ""
		}
	}
	return ""
}

@(private = "file")
partial_construction_is_result :: proc(path: ^Partial_Path, name: string) -> bool {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := path.scopes[scope_index]
		for entry in scope.hidden {
			if entry == name {
				for alias in scope.aliases {
					if alias.name == name {
						return alias.result
					}
				}
				return false
			}
		}
		for alias in scope.aliases {
			if alias.name == name {
				return alias.result
			}
		}
	}
	return false
}

@(private = "file")
partial_construction_mark_result :: proc(path: ^Partial_Path, name: string) {
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := &path.scopes[scope_index]
		for &alias in scope.aliases {
			if alias.name == name && alias.live >= 0 {
				alias.result = true
				return
			}
		}
	}
}

@(private = "file")
partial_construction_assign_name :: proc(path: ^Partial_Path, name: string, live: int) {
	if name == "_" {
		return
	}
	for scope_index := len(path.scopes) - 1; scope_index >= 0; scope_index -= 1 {
		scope := &path.scopes[scope_index]
		known := false
		for entry in scope.hidden {
			if entry == name {
				known = true
			}
		}
		for &alias in scope.aliases {
			if alias.name == name {
				alias.live = live
				if live < 0 {
					alias.result = false
				}
				return
			}
		}
		if known {
			result := false
			param := false
			for alias in scope.aliases {
				if alias.name == name {
					result, param = alias.result, alias.param
				}
			}
			append(&scope.aliases, Partial_Alias{name = name, live = live, result = result, param = param})
			return
		}
	}
	partial_construction_bind_alias(path, name, live, false)
}

@(private = "file")
partial_construction_retarget :: proc(path: ^Partial_Path, name: string, live: int) {
	if old, ok := partial_construction_lookup(path, name); ok && old.live != live {
		if len(partial_construction_visible(path, old.live)) == 1 {
			path.poisoned[old.live] = true
		}
	}
	partial_construction_assign_name(path, name, live)
}

@(private = "file")
partial_construction_call_clear :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	call: ^ast.Call_Expr,
) -> bool {
	callee := partial_construction_callee(call.expr)
	if partial_construction_declared(path, callee) || partial_construction_file_shadow(a.file, callee) {
		return false
	}
	for arg in call.args {
		value := partial_construction_value(arg)
		heap, is_heap := partial_construction_heap_call(a, value)
		_ = heap
		if !is_heap {
			continue
		}
		sel := partial_construction_pkg_ident(value)
		if sel != "" && partial_construction_declared(path, sel) {
			return false
		}
	}
	return true
}

@(private = "file")
partial_construction_pkg_ident :: proc(expr: ^ast.Expr) -> string {
	call := partial_construction_call(partial_construction_strip(expr))
	if call == nil {
		return ""
	}
	sel, ok := call.expr.derived_expr.(^ast.Selector_Expr)
	if !ok {
		return ""
	}
	ident, is_ident := sel.expr.derived_expr.(^ast.Ident)
	if !is_ident {
		return ""
	}
	return ident.name
}

@(private = "file")
partial_construction_expr_live :: proc(path: ^Partial_Path, expr: ^ast.Expr) -> int {
	lives := make([dynamic]int, context.temp_allocator)
	partial_construction_expr_lives(path, expr, &lives)
	if len(lives) == 1 {
		return lives[0]
	}
	return -1
}

@(private = "file")
partial_construction_expr_lives :: proc(path: ^Partial_Path, expr: ^ast.Expr, lives: ^[dynamic]int) {
	if expr == nil {
		return
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Proc_Lit:
		return
	case ^ast.Ident:
		if alias, ok := partial_construction_lookup(path, e.name); ok {
			partial_construction_add_live(lives, alias.live)
		}
	case ^ast.Paren_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
	case ^ast.Selector_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
	case ^ast.Index_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
		partial_construction_expr_lives(path, e.index, lives)
	case ^ast.Deref_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
	case ^ast.Unary_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
	case ^ast.Binary_Expr:
		partial_construction_expr_lives(path, e.left, lives)
		partial_construction_expr_lives(path, e.right, lives)
	case ^ast.Comp_Lit:
		for elem in e.elems {
			partial_construction_expr_lives(path, elem, lives)
		}
	case ^ast.Field_Value:
		partial_construction_expr_lives(path, e.value, lives)
	case ^ast.Call_Expr:
		for arg in e.args {
			partial_construction_expr_lives(path, arg, lives)
		}
	case ^ast.Or_Return_Expr:
		partial_construction_expr_lives(path, e.expr, lives)
	}
}

@(private = "file")
partial_construction_add_live :: proc(lives: ^[dynamic]int, live: int) {
	for have in lives {
		if have == live {
			return
		}
	}
	append(lives, live)
}

@(private = "file")
partial_construction_effects :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	expr: ^ast.Expr,
	unconditional: bool,
) {
	if expr == nil {
		return
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Paren_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
	case ^ast.Or_Return_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
		if unconditional {
			partial_construction_judge(a, path, nil, e.token.pos.line, true)
		}
	case ^ast.Or_Else_Expr:
		partial_construction_effects(a, path, e.x, unconditional)
	case ^ast.Call_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
		for arg in e.args {
			partial_construction_effects(a, path, partial_construction_value(arg), unconditional)
		}
		partial_construction_apply_call(a, path, e)
	case ^ast.Unary_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
	case ^ast.Binary_Expr:
		partial_construction_effects(a, path, e.left, unconditional)
		right := unconditional && e.op.kind != .Cmp_And && e.op.kind != .Cmp_Or
		partial_construction_effects(a, path, e.right, right)
	case ^ast.Selector_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
	case ^ast.Index_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
		partial_construction_effects(a, path, e.index, unconditional)
	case ^ast.Slice_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
		partial_construction_effects(a, path, e.low, unconditional)
		partial_construction_effects(a, path, e.high, unconditional)
	case ^ast.Deref_Expr:
		partial_construction_effects(a, path, e.expr, unconditional)
	case ^ast.Comp_Lit:
		for elem in e.elems {
			partial_construction_effects(a, path, elem, unconditional)
		}
	case ^ast.Field_Value:
		partial_construction_effects(a, path, e.value, unconditional)
	case ^ast.Ternary_If_Expr:
		partial_construction_effects(a, path, e.cond, unconditional)
	case ^ast.Ternary_When_Expr:
		partial_construction_effects(a, path, e.cond, unconditional)
	case ^ast.Type_Cast, ^ast.Auto_Cast:
		inner: ^ast.Expr
		#partial switch c in expr.derived_expr {
		case ^ast.Type_Cast:
			inner = c.expr
		case ^ast.Auto_Cast:
			inner = c.expr
		}
		partial_construction_effects(a, path, inner, unconditional)
	case ^ast.Proc_Lit:
		partial_construction_capture(path, e)
	}
}

@(private = "file")
partial_construction_capture :: proc(path: ^Partial_Path, proc_lit: ^ast.Proc_Lit) {
	for live in 0 ..< len(path.born) {
		if !path.born[live] || path.freed[live] || path.poisoned[live] {
			continue
		}
		for alias in partial_construction_visible(path, live) {
			if partial_construction_expr_mentions(proc_lit, alias.name) {
				path.poisoned[live] = true
			}
		}
	}
}

@(private = "file")
Partial_Hit :: struct {
	name: string,
	hit:  bool,
}

@(private = "file")
partial_construction_hit_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if v == nil || node == nil {
		return nil
	}
	hit := (^Partial_Hit)(v.data)
	if hit.hit {
		return nil
	}
	#partial switch n in node.derived {
	case ^ast.Ident:
		if n.name == hit.name {
			hit.hit = true
		}
	}
	return v
}

@(private = "file")
partial_construction_expr_mentions :: proc(proc_lit: ^ast.Proc_Lit, name: string) -> bool {
	hit := Partial_Hit {
		name = name,
	}
	v := ast.Visitor {
		visit = partial_construction_hit_visit,
		data  = &hit,
	}
	ast.walk(&v, proc_lit)
	return hit.hit
}

@(private = "file")
partial_construction_apply_call :: proc(a: ^Partial_Analyser, path: ^Partial_Path, call: ^ast.Call_Expr) {
	callee := partial_construction_callee(call.expr)
	shadowed := partial_construction_declared(path, callee) || partial_construction_file_shadow(a.file, callee)
	cleanup := partial_construction_cleanup(callee)
	quiet := !shadowed && (callee == "len" || callee == "cap")
	keeps := !shadowed && partial_construction_keeps_header(callee)
	for live in 0 ..< len(path.born) {
		if !path.born[live] || path.freed[live] || path.poisoned[live] {
			continue
		}
		mention := partial_construction_call_mention(path, call, live)
		if !mention.value && !mention.addr {
			continue
		}
		if cleanup && (mention.value || mention.addr) {
			path.freed[live] = true
			continue
		}
		if quiet && mention.value {
			continue
		}
		if keeps && mention.addr && !mention.value {
			continue
		}
		path.poisoned[live] = true
	}
}

@(private = "file")
partial_construction_keeps_header :: proc(name: string) -> bool {
	switch name {
	case "append", "append_elem", "append_elems", "append_nothing", "inject_at", "inject_at_elem",
	     "assign_at", "assign_at_elem", "pop", "pop_front", "pop_safe", "unordered_remove",
	     "clear", "clear_dynamic_array", "reserve", "resize", "shrink":
		return true
	case:
		return false
	}
}

@(private = "file")
partial_construction_cleanup :: proc(name: string) -> bool {
	switch name {
	case "free", "mem_free", "mem_free_with_size", "delete", "delete_slice", "delete_dynamic_array",
	     "delete_map", "delete_soa_slice", "delete_soa_dynamic_array", "delete_string", "delete_cstring",
	     "destroy", "deinit", "close":
		return true
	}
	for verb in ([]string{"free", "destroy", "deinit", "delete", "close"}) {
		if len(name) > len(verb) && strings.has_prefix(name, verb) && name[len(verb)] == '_' {
			return true
		}
		if len(name) > len(verb) + 1 &&
		   name[len(name) - len(verb) - 1] == '_' &&
		   strings.has_suffix(name, verb) {
			return true
		}
	}
	return false
}

@(private = "file")
partial_construction_call_mention :: proc(
	path: ^Partial_Path,
	call: ^ast.Call_Expr,
	live: int,
) -> Partial_Mention {
	mention: Partial_Mention
	for arg in call.args {
		one := partial_construction_mention_expr(path, partial_construction_value(arg), live, false)
		mention.value ||= one.value
		mention.addr ||= one.addr
	}
	return mention
}

@(private = "file")
partial_construction_mention_expr :: proc(
	path: ^Partial_Path,
	expr: ^ast.Expr,
	live: int,
	addressed: bool,
) -> Partial_Mention {
	mention: Partial_Mention
	if expr == nil {
		return {}
	}
	#partial switch e in expr.derived_expr {
	case ^ast.Ident:
		if alias, ok := partial_construction_lookup(path, e.name); ok && alias.live == live {
			if addressed {
				mention.addr = true
			} else {
				mention.value = true
			}
		}
	case ^ast.Paren_Expr:
		return partial_construction_mention_expr(path, e.expr, live, addressed)
	case ^ast.Unary_Expr:
		if e.op.kind == .And {
			return partial_construction_mention_expr(path, e.expr, live, true)
		}
		return partial_construction_mention_expr(path, e.expr, live, false)
	case ^ast.Selector_Expr:
		inner := partial_construction_mention_expr(path, e.expr, live, addressed)
		mention.value ||= inner.value
		mention.addr ||= inner.addr
	case ^ast.Deref_Expr:
		inner := partial_construction_mention_expr(path, e.expr, live, false)
		mention.value ||= inner.value
	case ^ast.Index_Expr:
		base := partial_construction_mention_expr(path, e.expr, live, addressed)
		index := partial_construction_mention_expr(path, e.index, live, false)
		mention.value ||= base.value || index.value
		mention.addr ||= base.addr
	case ^ast.Comp_Lit:
		for elem in e.elems {
			inner := partial_construction_mention_expr(path, elem, live, false)
			mention.value ||= inner.value
			mention.addr ||= inner.addr
		}
	case ^ast.Field_Value:
		inner := partial_construction_mention_expr(path, e.value, live, false)
		mention.value ||= inner.value
		mention.addr ||= inner.addr
	case ^ast.Call_Expr:
		for arg in e.args {
			inner := partial_construction_mention_expr(path, partial_construction_value(arg), live, false)
			mention.value ||= inner.value
			mention.addr ||= inner.addr
		}
	case ^ast.Binary_Expr:
		left := partial_construction_mention_expr(path, e.left, live, false)
		right := partial_construction_mention_expr(path, e.right, live, false)
		mention.value ||= left.value || right.value
		mention.addr ||= left.addr || right.addr
	}
	return mention
}

@(private = "file")
partial_construction_judge :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	results: []^ast.Expr,
	line: int,
	early: bool,
) {
	scratch := partial_construction_clone(path)
	for depth in 0 ..< len(scratch.scopes) {
		partial_construction_run_defers(a, &scratch, depth)
	}
	last := ""
	if len(a.named) > 0 {
		last = a.named[len(a.named) - 1]
	}
	for live in 0 ..< len(a.metas) {
		if !scratch.born[live] || scratch.freed[live] || scratch.poisoned[live] || a.reported[live] {
			continue
		}
		aliases := partial_construction_visible(&scratch, live)
		if len(aliases) == 0 {
			continue
		}
		if partial_construction_transferred(a, &scratch, live, aliases, results, early, last) {
			continue
		}
		report := line
		if !a.file.added[report] {
			report = a.metas[live].line
		}
		if !a.file.added[report] {
			continue
		}
		a.reported[live] = true
		binding := a.metas[live].binding
		if binding == "" {
			binding = aliases[0].name
		}
		prev := context.allocator
		context.allocator = a.file.alloc
		message := fmt.aprintf(
			"`%s` is allocated by `%s` with `%s` and this failure return leaves it behind",
			binding,
			a.metas[live].via,
			a.metas[live].allocator,
		)
		context.allocator = prev
		append(
			a.file.out,
			static(
				"odin-partial-construction",
				.Must_Fix,
				message,
				"free or delete it before that return, or defer the cleanup. Returning the value, or storing it in a named result this return hands back, gives it to the caller",
				file = a.file.path,
				line = report,
				symbol = binding,
			),
		)
	}
}

@(private = "file")
partial_construction_transferred :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	live: int,
	aliases: []Partial_Alias,
	results: []^ast.Expr,
	early: bool,
	last: string,
) -> bool {
	_ = a
	_ = path
	_ = live
	if early || len(results) == 0 {
		for alias in aliases {
			if !alias.result {
				continue
			}
			if early && alias.name == last {
				continue
			}
			return true
		}
		if len(results) == 0 {
			return false
		}
	}
	for result in results {
		mention := partial_construction_mention_expr(path, result, live, false)
		if mention.value {
			return true
		}
	}
	return false
}

@(private = "file")
partial_construction_run_defers :: proc(a: ^Partial_Analyser, path: ^Partial_Path, depth: int) {
	_ = a
	if depth < 0 || depth >= len(path.scopes) {
		return
	}
	defers := path.scopes[depth].defers
	for i := len(defers) - 1; i >= 0; i -= 1 {
		partial_construction_defer_stmt(path, defers[i])
	}
}

@(private = "file")
partial_construction_defer_stmt :: proc(path: ^Partial_Path, stmt: ^ast.Stmt) {
	for live in 0 ..< len(path.born) {
		if !path.born[live] || path.freed[live] || path.poisoned[live] {
			continue
		}
		#partial switch partial_construction_defer_effect(path, stmt, live) {
		case .Free:
			path.freed[live] = true
		case .Poison:
			path.poisoned[live] = true
		}
	}
}

@(private = "file")
Partial_Defer :: enum {
	None,
	Free,
	Poison,
}

@(private = "file")
partial_construction_defer_effect :: proc(
	path: ^Partial_Path,
	stmt: ^ast.Stmt,
	live: int,
) -> Partial_Defer {
	if stmt == nil {
		return .None
	}
	#partial switch n in stmt.derived_stmt {
	case ^ast.Expr_Stmt:
		return partial_construction_defer_expr(path, n.expr, live)
	case ^ast.Block_Stmt:
		effect := Partial_Defer.None
		for inner in n.stmts {
			one := partial_construction_defer_effect(path, inner, live)
			if one == .Free {
				return .Free
			}
			if one == .Poison {
				effect = .Poison
			}
		}
		return effect
	case ^ast.Assign_Stmt, ^ast.Value_Decl, ^ast.If_Stmt, ^ast.For_Stmt, ^ast.Range_Stmt,
	     ^ast.Switch_Stmt, ^ast.Return_Stmt:
		if partial_construction_stmt_mentions(path, stmt, live) {
			return .Poison
		}
	}
	return .None
}

@(private = "file")
partial_construction_defer_expr :: proc(
	path: ^Partial_Path,
	expr: ^ast.Expr,
	live: int,
) -> Partial_Defer {
	call := partial_construction_call(partial_construction_strip(expr))
	if call == nil {
		if partial_construction_mention_expr(path, expr, live, false).value ||
		   partial_construction_mention_expr(path, expr, live, false).addr {
			return .Poison
		}
		return .None
	}
	mention := partial_construction_call_mention(path, call, live)
	if !mention.value && !mention.addr {
		return .None
	}
	if partial_construction_cleanup(partial_construction_callee(call.expr)) {
		return .Free
	}
	return .Poison
}

@(private = "file")
partial_construction_stmt_mentions :: proc(path: ^Partial_Path, stmt: ^ast.Stmt, live: int) -> bool {
	for alias in partial_construction_visible(path, live) {
		hit := Partial_Hit {
			name = alias.name,
		}
		v := ast.Visitor {
			visit = partial_construction_hit_visit,
			data  = &hit,
		}
		ast.walk(&v, stmt)
		if hit.hit {
			return true
		}
	}
	return false
}

@(private = "file")
partial_construction_failure :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	cond: ^ast.Expr,
) -> (
	then_fails, else_fails: bool,
) {
	cur := partial_construction_unwrap(cond)
	if cur == nil {
		return
	}
	#partial switch e in cur.derived_expr {
	case ^ast.Unary_Expr:
		if e.op.kind != .Not {
			return
		}
		if partial_construction_bool_target(a, path, e.expr) {
			return true, false
		}
	case ^ast.Ident:
		if flag, ok := partial_construction_flag(path, e.name); ok && flag.boolean {
			return false, true
		}
	case ^ast.Call_Expr:
		return false, true
	case ^ast.Binary_Expr:
		return partial_construction_compare(a, path, e)
	}
	return
}

@(private = "file")
partial_construction_bool_target :: proc(a: ^Partial_Analyser, path: ^Partial_Path, expr: ^ast.Expr) -> bool {
	cur := partial_construction_unwrap(expr)
	if cur == nil {
		return false
	}
	#partial switch e in cur.derived_expr {
	case ^ast.Ident:
		flag, ok := partial_construction_flag(path, e.name)
		return ok && flag.boolean
	case ^ast.Call_Expr:
		return true
	}
	return false
}

@(private = "file")
partial_construction_compare :: proc(
	a: ^Partial_Analyser,
	path: ^Partial_Path,
	e: ^ast.Binary_Expr,
) -> (
	then_fails, else_fails: bool,
) {
	left := partial_construction_unwrap(e.left)
	right := partial_construction_unwrap(e.right)
	target := left
	other := right
	if partial_construction_const_name(a, path, right) == "" &&
	   partial_construction_const_name(a, path, left) != "" {
		target, other = right, left
	}
	constant := partial_construction_const_name(a, path, other)
	if constant == "" || (e.op.kind != .Cmp_Eq && e.op.kind != .Not_Eq) {
		return
	}
	bool_target := partial_construction_bool_target(a, path, target)
	nil_target := false
	if ident, is_ident := target.derived_expr.(^ast.Ident); is_ident {
		if flag, ok := partial_construction_flag(path, ident.name); ok {
			nil_target = flag.nilable
		}
	}
	positive: bool
	switch constant {
	case "false":
		positive = bool_target
	case "true":
		positive = bool_target
	case "nil":
		positive = nil_target
	case:
		return
	}
	if !positive {
		return
	}
	// `== false`, `!= true`, and `!= nil` are the failure polarity.
	// `== true`, `!= false`, and `== nil` are the success polarity.
	failure := e.op.kind == .Not_Eq
	if constant == "false" || constant == "nil" {
		failure = e.op.kind == .Cmp_Eq && constant == "false" || e.op.kind == .Not_Eq && constant == "nil"
	}
	if constant == "true" {
		failure = e.op.kind == .Not_Eq
	}
	if constant == "false" {
		failure = e.op.kind == .Cmp_Eq
	}
	if failure {
		return true, false
	}
	return false, true
}

@(private = "file")
partial_construction_const_name :: proc(a: ^Partial_Analyser, path: ^Partial_Path, expr: ^ast.Expr) -> string {
	cur := partial_construction_unwrap(expr)
	if cur == nil {
		return ""
	}
	ident, ok := cur.derived_expr.(^ast.Ident)
	if !ok {
		return ""
	}
	if partial_construction_declared(path, ident.name) || a.file.names[ident.name] {
		return ""
	}
	switch ident.name {
	case "true", "false", "nil":
		return ident.name
	}
	return ""
}

@(private = "file")
partial_construction_unwrap :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	cur := expr
	for cur != nil {
		paren, ok := cur.derived_expr.(^ast.Paren_Expr)
		if !ok {
			return cur
		}
		cur = paren.expr
	}
	return cur
}

@(private = "file")
partial_construction_clone :: proc(path: ^Partial_Path) -> Partial_Path {
	out := Partial_Path {
		born     = make([]bool, len(path.born)),
		freed    = make([]bool, len(path.freed)),
		poisoned = make([]bool, len(path.poisoned)),
	}
	copy(out.born, path.born)
	copy(out.freed, path.freed)
	copy(out.poisoned, path.poisoned)
	for scope in path.scopes {
		cloned := Partial_Scope{}
		for alias in scope.aliases {
			append(&cloned.aliases, alias)
		}
		for name in scope.hidden {
			append(&cloned.hidden, name)
		}
		for flag in scope.flags {
			append(&cloned.flags, flag)
		}
		for defer_stmt in scope.defers {
			append(&cloned.defers, defer_stmt)
		}
		append(&out.scopes, cloned)
	}
	return out
}

@(private = "file")
partial_construction_poison_diff :: proc(path, clone: ^Partial_Path) {
	for i in 0 ..< len(path.born) {
		if !path.born[i] {
			continue
		}
		if clone.freed[i] ||
		   clone.poisoned[i] ||
		   clone.born[i] != path.born[i] ||
		   !partial_construction_same_aliases(path, clone, i) {
			path.poisoned[i] = true
		}
	}
}
