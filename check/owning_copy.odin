package check

// A dynamic array or map header is the owner of its backing block.
// make with a positive length or capacity and the heap allocator proves
// that block. Assignment copies the header. delete takes the header by
// value, so a second local delete frees the same heap pointer again.
// context.allocator, temp allocators, empty makes, named element types,
// and any use that might reallocate or free are not proof.

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:strconv"
import "core:strings"

import "../finding"

@(private = "file")
Owning_Copy_Ids :: struct {
	next_slot, next_alloc: int,
}

@(private = "file")
Owning_Copy_Slot :: struct {
	id, alloc, copy_line: int,
}

@(private = "file")
Owning_Copy_Frame :: struct {
	binds: map[string]Owning_Copy_Slot,
}

@(private = "file")
Owning_Copy_Alloc :: struct {
	line:     int,
	kind:     string,
	dead:     bool,
	reported: bool,
}

@(private = "file")
Owning_Copy_Del :: struct {
	slot, line, copy_line: int,
	name:                  string,
}

@(private = "file")
Owning_Copy_Hit :: struct {
	alloc:      int,
	lines:      [4]int,
	first:      string,
	second:     string,
	kind:       string,
	alloc_line: int,
}

@(private = "file")
Owning_Copy_State :: struct {
	ids:      ^Owning_Copy_Ids,
	imports:  map[string]string,
	nonzero:  map[string]bool,
	frames:   [dynamic]Owning_Copy_Frame,
	allocs:   map[int]Owning_Copy_Alloc,
	deleted:  map[int]Owning_Copy_Del,
	hits:     [dynamic]Owning_Copy_Hit,
	keep:     runtime.Allocator,
}

// check_owning_copy reports a local dynamic array or map, allocated by
// make with the heap allocator and a positive length or capacity, copied
// to another local, then deleted through both names.
check_owning_copy :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
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
		added := make(map[int]bool)
		for line in s.c.added[path] {
			added[line.line] = true
		}
		file := parse_odin_source(path, string(src))
		if file == nil {
			continue
		}

		ids := new(Owning_Copy_Ids)
		base := Owning_Copy_Frame {
			binds = make(map[string]Owning_Copy_Slot),
		}
		imports := make(map[string]string)
		for decl in file.decls {
			#partial switch d in decl.derived {
			case ^ast.Import_Decl:
				owning_copy_import(&imports, d)
			case ^ast.Value_Decl:
				for name in d.names {
					text := owning_copy_ident(name)
					if text == "" || text == "_" {
						continue
					}
					ids.next_slot += 1
					base.binds[text] = Owning_Copy_Slot {
						id = ids.next_slot,
					}
				}
			}
		}

		procs := make([dynamic]^ast.Proc_Lit)
		visitor := ast.Visitor {
			visit = owning_copy_visit,
			data  = &procs,
		}
		for decl in file.decls {
			ast.walk(&visitor, decl)
		}

		nonzero := owning_copy_builtins()
		for proc_lit in procs {
			st := Owning_Copy_State {
				ids      = ids,
				imports  = imports,
				nonzero  = nonzero,
				allocs   = make(map[int]Owning_Copy_Alloc),
				deleted  = make(map[int]Owning_Copy_Del),
				keep     = keep,
			}
			file_frame := Owning_Copy_Frame {
				binds = make(map[string]Owning_Copy_Slot),
			}
			for name, slot in base.binds {
				file_frame.binds[name] = slot
			}
			append(&st.frames, file_frame)
			owning_copy_push(&st)
			if proc_lit.type != nil && proc_lit.type.params != nil {
				for field in proc_lit.type.params.list {
					for name in field.names {
						owning_copy_bind(&st, owning_copy_ident(name), 0, 0)
					}
				}
			}
			if block, is_block := proc_lit.body.derived.(^ast.Block_Stmt); is_block {
				owning_copy_stmts(&st, block.stmts)
			} else {
				owning_copy_stmt(&st, proc_lit.body)
			}
			owning_copy_emit(&st, path, added, out)
		}
	}
}

@(private = "file")
owning_copy_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	if proc_lit, ok := node.derived.(^ast.Proc_Lit); ok && proc_lit.body != nil {
		append((^[dynamic]^ast.Proc_Lit)(v.data), proc_lit)
	}
	return v
}

@(private = "file")
owning_copy_import :: proc(imports: ^map[string]string, decl: ^ast.Import_Decl) {
	name := decl.name.text
	path := strings.trim(decl.relpath.text, "\"")
	if name == "" {
		cut := path
		if i := strings.last_index(cut, ":"); i >= 0 {
			cut = cut[i + 1:]
		}
		if i := strings.last_index(cut, "/"); i >= 0 {
			cut = cut[i + 1:]
		}
		name = cut
	}
	if name == "" || name == "." || name == "_" {
		return
	}
	imports[name] = path
}

@(private = "file")
owning_copy_emit :: proc(
	st: ^Owning_Copy_State,
	path: string,
	added: map[int]bool,
	out: ^[dynamic]finding.Finding,
) {
	seen := make(map[int]bool)
	context.allocator = st.keep
	for hit in st.hits {
		if seen[hit.alloc] {
			continue
		}
		line := 0
		for candidate in hit.lines {
			if candidate != 0 && added[candidate] && candidate > line {
				line = candidate
			}
		}
		if line == 0 {
			continue
		}
		seen[hit.alloc] = true
		append(
			out,
			static(
				"odin-owning-copy",
				.Must_Fix,
				fmt.aprintf(
					"`%s` and `%s` are copies of one %s created by `make` on line %d; both are passed to `delete`, which frees that heap block twice because `delete` takes the header by value",
					hit.second,
					hit.first,
					hit.kind,
					hit.alloc_line,
				),
				"keep a single owner and delete it once; pass a pointer instead of copying the header, or assign `{}` to the extra copy before any second delete",
				file = path,
				line = line,
				symbol = hit.second,
			),
		)
	}
}

@(private = "file")
owning_copy_push :: proc(st: ^Owning_Copy_State) {
	append(&st.frames, Owning_Copy_Frame{binds = make(map[string]Owning_Copy_Slot)})
}

@(private = "file")
owning_copy_pop :: proc(st: ^Owning_Copy_State) {
	// Frame 0 is the file and frame 1 is the procedure. Blocks push above those.
	if len(st.frames) > 2 {
		pop(&st.frames)
	}
}

@(private = "file")
owning_copy_lookup :: proc(st: ^Owning_Copy_State, name: string) -> (Owning_Copy_Slot, bool) {
	for i := len(st.frames) - 1; i >= 0; i -= 1 {
		if slot, ok := st.frames[i].binds[name]; ok {
			return slot, true
		}
	}
	return {}, false
}

@(private = "file")
owning_copy_bound :: proc(st: ^Owning_Copy_State, name: string) -> bool {
	if _, ok := owning_copy_lookup(st, name); ok {
		return true
	}
	_, ok := st.imports[name]
	return ok
}

@(private = "file")
owning_copy_bind :: proc(st: ^Owning_Copy_State, name: string, alloc, copy_line: int) {
	if name == "" || name == "_" {
		return
	}
	st.ids.next_slot += 1
	st.frames[len(st.frames) - 1].binds[name] = Owning_Copy_Slot {
		id        = st.ids.next_slot,
		alloc     = alloc,
		copy_line = copy_line,
	}
}

@(private = "file")
owning_copy_store :: proc(st: ^Owning_Copy_State, name: string, alloc, copy_line: int) {
	if name == "" || name == "_" {
		return
	}
	for i := len(st.frames) - 1; i >= 0; i -= 1 {
		slot, ok := st.frames[i].binds[name]
		if !ok {
			continue
		}
		slot.alloc = alloc
		slot.copy_line = copy_line
		st.frames[i].binds[name] = slot
		return
	}
}

@(private = "file")
owning_copy_live :: proc(st: ^Owning_Copy_State, id: int) -> bool {
	if id == 0 {
		return false
	}
	alloc, ok := st.allocs[id]
	return ok && !alloc.dead && !alloc.reported
}

@(private = "file")
owning_copy_kill_name :: proc(st: ^Owning_Copy_State, name: string) {
	slot, ok := owning_copy_lookup(st, name)
	if !ok || slot.alloc == 0 {
		return
	}
	alloc := st.allocs[slot.alloc]
	alloc.dead = true
	st.allocs[slot.alloc] = alloc
}

@(private = "file")
owning_copy_kill_all :: proc(st: ^Owning_Copy_State) {
	ids := make([dynamic]int)
	for id in st.allocs {
		append(&ids, id)
	}
	for id in ids {
		alloc := st.allocs[id]
		alloc.dead = true
		st.allocs[id] = alloc
	}
}

@(private = "file")
owning_copy_new_alloc :: proc(st: ^Owning_Copy_State, kind: string, line: int) -> int {
	st.ids.next_alloc += 1
	id := st.ids.next_alloc
	st.allocs[id] = Owning_Copy_Alloc {
		line = line,
		kind = kind,
	}
	return id
}

@(private = "file")
owning_copy_clone :: proc(st: ^Owning_Copy_State) -> Owning_Copy_State {
	out := st^
	out.frames = make([dynamic]Owning_Copy_Frame)
	for frame in st.frames {
		copy := Owning_Copy_Frame {
			binds = make(map[string]Owning_Copy_Slot),
		}
		for name, slot in frame.binds {
			copy.binds[name] = slot
		}
		append(&out.frames, copy)
	}
	out.allocs = make(map[int]Owning_Copy_Alloc)
	for id, alloc in st.allocs {
		out.allocs[id] = alloc
	}
	out.deleted = make(map[int]Owning_Copy_Del)
	for id, del in st.deleted {
		out.deleted[id] = del
	}
	out.hits = make([dynamic]Owning_Copy_Hit)
	return out
}

@(private = "file")
owning_copy_join :: proc(st: ^Owning_Copy_State, branches: []Owning_Copy_State) {
	for branch in branches {
		for hit in branch.hits {
			append(&st.hits, hit)
		}
	}
	ids := make([dynamic]int)
	for id in st.allocs {
		append(&ids, id)
	}
	for id in ids {
		for branch in branches {
			alloc, ok := branch.allocs[id]
			if ok && (alloc.dead || id in branch.deleted) {
				current := st.allocs[id]
				current.dead = true
				st.allocs[id] = current
				break
			}
		}
	}
}

@(private = "file")
owning_copy_branch :: proc(st: ^Owning_Copy_State, stmt: ^ast.Stmt) -> Owning_Copy_State {
	branch := owning_copy_clone(st)
	owning_copy_stmt(&branch, stmt)
	return branch
}

@(private = "file")
owning_copy_stmts :: proc(st: ^Owning_Copy_State, stmts: []^ast.Stmt) -> bool {
	for stmt in stmts {
		if owning_copy_stmt(st, stmt) {
			return true
		}
	}
	return false
}

@(private = "file")
owning_copy_stmt :: proc(st: ^Owning_Copy_State, stmt: ^ast.Stmt) -> bool {
	if stmt == nil {
		return false
	}
	#partial switch node in stmt.derived {
	case ^ast.Empty_Stmt, ^ast.Defer_Stmt:
		return false
	case ^ast.Bad_Stmt:
		owning_copy_kill_all(st)
	case ^ast.Tag_Stmt:
		return owning_copy_stmt(st, node.stmt)
	case ^ast.Block_Stmt:
		owning_copy_push(st)
		stop := owning_copy_stmts(st, node.stmts)
		owning_copy_pop(st)
		return stop
	case ^ast.Value_Decl:
		owning_copy_value(st, node)
	case ^ast.Assign_Stmt:
		owning_copy_assign(st, node)
	case ^ast.Expr_Stmt:
		owning_copy_touch(st, node.expr, false)
	case ^ast.Return_Stmt:
		for result in node.results {
			owning_copy_touch(st, result, false)
		}
		return true
	case ^ast.Branch_Stmt:
		return true
	case ^ast.If_Stmt:
		owning_copy_if(st, node)
	case ^ast.When_Stmt:
		owning_copy_when(st, node)
	case ^ast.For_Stmt:
		owning_copy_for(st, node)
	case ^ast.Range_Stmt:
		owning_copy_range(st, node)
	case ^ast.Switch_Stmt:
		owning_copy_switch(st, node)
	case ^ast.Type_Switch_Stmt:
		owning_copy_type_switch(st, node)
	case ^ast.Using_Stmt:
		owning_copy_kill_all(st)
	case:
		owning_copy_kill_all(st)
	}
	return false
}

@(private = "file")
owning_copy_value :: proc(st: ^Owning_Copy_State, decl: ^ast.Value_Decl) {
	for value in decl.values {
		owning_copy_touch(st, value, false)
	}
	if !decl.is_mutable {
		for name in decl.names {
			owning_copy_bind(st, owning_copy_ident(name), 0, 0)
		}
		return
	}
	if len(decl.values) == 1 {
		value := ast.strip_or_return_expr(decl.values[0])
		if kind, ok := owning_copy_make(st, value); ok && len(decl.names) >= 1 {
			id := owning_copy_new_alloc(st, kind, decl.pos.line)
			owning_copy_bind(st, owning_copy_ident(decl.names[0]), id, 0)
			for name in decl.names[1:] {
				owning_copy_bind(st, owning_copy_ident(name), 0, 0)
			}
			return
		}
		if len(decl.names) == 1 {
			if src := owning_copy_ident(value); src != "" {
				slot, found := owning_copy_lookup(st, src)
				if found && owning_copy_live(st, slot.alloc) {
					owning_copy_bind(st, owning_copy_ident(decl.names[0]), slot.alloc, decl.pos.line)
					return
				}
			}
		}
	} else if len(decl.values) == len(decl.names) {
		for name, index in decl.names {
			owning_copy_bind_value(st, owning_copy_ident(name), decl.values[index], decl.pos.line, true)
		}
		return
	}
	for name in decl.names {
		owning_copy_bind(st, owning_copy_ident(name), 0, 0)
	}
}

@(private = "file")
owning_copy_bind_value :: proc(
	st: ^Owning_Copy_State,
	name: string,
	value: ^ast.Expr,
	line: int,
	fresh: bool,
) {
	expr := ast.strip_or_return_expr(value)
	alloc, copy_line: int
	if kind, ok := owning_copy_make(st, expr); ok {
		alloc = owning_copy_new_alloc(st, kind, line)
	} else if src := owning_copy_ident(expr); src != "" {
		slot, found := owning_copy_lookup(st, src)
		if found && owning_copy_live(st, slot.alloc) {
			alloc = slot.alloc
			copy_line = line
		}
	}
	if fresh {
		owning_copy_bind(st, name, alloc, copy_line)
	} else {
		owning_copy_store(st, name, alloc, copy_line)
	}
}

@(private = "file")
owning_copy_assign :: proc(st: ^Owning_Copy_State, stmt: ^ast.Assign_Stmt) {
	if stmt.op.kind != .Eq || len(stmt.lhs) != len(stmt.rhs) {
		for value in stmt.rhs {
			owning_copy_touch(st, value, false)
		}
		for name in stmt.lhs {
			owning_copy_detach(st, name)
		}
		return
	}
	for name, index in stmt.lhs {
		owning_copy_touch(st, stmt.rhs[index], false)
		if text := owning_copy_ident(name); text != "" {
			owning_copy_bind_value(st, text, stmt.rhs[index], stmt.pos.line, false)
		} else {
			owning_copy_detach(st, name)
		}
	}
}

// owning_copy_detach drops a plain name from the allocation and kills the
// allocation when the assignment is not a whole-value store. An index or
// selector store can reallocate a map header or pass the container out.
@(private = "file")
owning_copy_detach :: proc(st: ^Owning_Copy_State, expr: ^ast.Expr) {
	if text := owning_copy_ident(expr); text != "" {
		owning_copy_store(st, text, 0, 0)
		return
	}
	owning_copy_touch(st, expr, true)
}

@(private = "file")
owning_copy_if :: proc(st: ^Owning_Copy_State, stmt: ^ast.If_Stmt) {
	owning_copy_push(st)
	defer owning_copy_pop(st)
	if stmt.init != nil && owning_copy_stmt(st, stmt.init) {
		return
	}
	owning_copy_touch(st, stmt.cond, false)
	branches := make([dynamic]Owning_Copy_State)
	append(&branches, owning_copy_branch(st, stmt.body))
	if stmt.else_stmt != nil {
		append(&branches, owning_copy_branch(st, stmt.else_stmt))
	}
	owning_copy_join(st, branches[:])
}

@(private = "file")
owning_copy_when :: proc(st: ^Owning_Copy_State, stmt: ^ast.When_Stmt) {
	owning_copy_touch(st, stmt.cond, false)
	branches := make([dynamic]Owning_Copy_State)
	append(&branches, owning_copy_branch(st, stmt.body))
	if stmt.else_stmt != nil {
		append(&branches, owning_copy_branch(st, stmt.else_stmt))
	}
	owning_copy_join(st, branches[:])
}

@(private = "file")
owning_copy_for :: proc(st: ^Owning_Copy_State, stmt: ^ast.For_Stmt) {
	owning_copy_push(st)
	defer owning_copy_pop(st)
	if stmt.init != nil && owning_copy_stmt(st, stmt.init) {
		return
	}
	owning_copy_touch(st, stmt.cond, false)
	branch := owning_copy_clone(st)
	stopped := false
	if stmt.body != nil {
		stopped = owning_copy_stmt(&branch, stmt.body)
	}
	if !stopped && stmt.post != nil {
		owning_copy_stmt(&branch, stmt.post)
	}
	owning_copy_join(st, []Owning_Copy_State{branch})
}

@(private = "file")
owning_copy_range :: proc(st: ^Owning_Copy_State, stmt: ^ast.Range_Stmt) {
	owning_copy_push(st)
	defer owning_copy_pop(st)
	if stmt.init != nil && owning_copy_stmt(st, stmt.init) {
		return
	}
	owning_copy_touch(st, stmt.expr, false)
	for name in stmt.vals {
		owning_copy_bind(st, owning_copy_ident(name), 0, 0)
	}
	owning_copy_join(st, []Owning_Copy_State{owning_copy_branch(st, stmt.body)})
}

@(private = "file")
owning_copy_switch :: proc(st: ^Owning_Copy_State, stmt: ^ast.Switch_Stmt) {
	owning_copy_push(st)
	defer owning_copy_pop(st)
	if stmt.init != nil && owning_copy_stmt(st, stmt.init) {
		return
	}
	owning_copy_touch(st, stmt.cond, false)
	owning_copy_cases(st, stmt.body)
}

@(private = "file")
owning_copy_type_switch :: proc(st: ^Owning_Copy_State, stmt: ^ast.Type_Switch_Stmt) {
	owning_copy_push(st)
	defer owning_copy_pop(st)
	if stmt.tag != nil && owning_copy_stmt(st, stmt.tag) {
		return
	}
	owning_copy_touch(st, stmt.expr, false)
	owning_copy_cases(st, stmt.body)
}

@(private = "file")
owning_copy_cases :: proc(st: ^Owning_Copy_State, body: ^ast.Stmt) {
	block, ok := body.derived.(^ast.Block_Stmt)
	if !ok || body == nil {
		owning_copy_kill_all(st)
		return
	}
	branches := make([dynamic]Owning_Copy_State)
	for stmt in block.stmts {
		clause, is_case := stmt.derived.(^ast.Case_Clause)
		if !is_case {
			continue
		}
		branch := owning_copy_clone(st)
		for expr in clause.list {
			owning_copy_touch(&branch, expr, false)
		}
		owning_copy_stmts(&branch, clause.body)
		append(&branches, branch)
	}
	owning_copy_join(st, branches[:])
}

@(private = "file")
owning_copy_on_delete :: proc(st: ^Owning_Copy_State, name: string, line: int) {
	slot, ok := owning_copy_lookup(st, name)
	if !ok || !owning_copy_live(st, slot.alloc) {
		return
	}
	if prev, done := st.deleted[slot.alloc]; done {
		if prev.slot == slot.id {
			return
		}
		copy_line := slot.copy_line
		if copy_line == 0 {
			copy_line = prev.copy_line
		}
		alloc := st.allocs[slot.alloc]
		append(&st.hits, Owning_Copy_Hit{
			alloc      = slot.alloc,
			lines      = {alloc.line, copy_line, prev.line, line},
			first      = prev.name,
			second     = name,
			kind       = alloc.kind,
			alloc_line = alloc.line,
		})
		alloc.reported = true
		st.allocs[slot.alloc] = alloc
		return
	}
	st.deleted[slot.alloc] = Owning_Copy_Del {
		slot      = slot.id,
		line      = line,
		copy_line = slot.copy_line,
		name      = name,
	}
}

@(private = "file")
owning_copy_delete_applies :: proc(name, kind: string) -> bool {
	switch name {
	case "delete":
		return true
	case "delete_dynamic_array":
		return kind == "dynamic array"
	case "delete_soa_dynamic_array":
		return kind == "SOA dynamic array"
	case "delete_map":
		return kind == "map"
	}
	return false
}

@(private = "file")
owning_copy_touch :: proc(st: ^Owning_Copy_State, expr: ^ast.Expr, kill: bool) {
	if expr == nil {
		return
	}
	#partial switch node in expr.derived_expr {
	case ^ast.Ident:
		if kill {
			owning_copy_kill_name(st, node.name)
		}
	case ^ast.Basic_Lit, ^ast.Basic_Directive, ^ast.Implicit, ^ast.Undef, ^ast.Proc_Lit:
	case ^ast.Paren_Expr:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Or_Return_Expr:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Or_Branch_Expr:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Or_Else_Expr:
		owning_copy_touch(st, node.x, kill)
		owning_copy_touch(st, node.y, kill)
	case ^ast.Unary_Expr:
		if node.op.kind == .And {
			if text := owning_copy_ident(node.expr); text != "" {
				owning_copy_kill_name(st, text)
			} else {
				owning_copy_touch(st, node.expr, true)
			}
		} else {
			owning_copy_touch(st, node.expr, kill)
		}
	case ^ast.Binary_Expr:
		owning_copy_touch(st, node.left, kill)
		owning_copy_touch(st, node.right, kill)
	case ^ast.Selector_Expr:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Deref_Expr:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Index_Expr:
		owning_copy_touch(st, node.expr, kill)
		owning_copy_touch(st, node.index, kill)
	case ^ast.Slice_Expr:
		owning_copy_touch(st, node.expr, kill)
		owning_copy_touch(st, node.low, kill)
		owning_copy_touch(st, node.high, kill)
	case ^ast.Call_Expr:
		owning_copy_call(st, node)
	case ^ast.Field_Value:
		owning_copy_touch(st, node.value, kill)
	case ^ast.Comp_Lit:
		for elem in node.elems {
			owning_copy_touch(st, elem, kill)
		}
	case ^ast.Type_Cast:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Auto_Cast:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Ellipsis:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Ternary_If_Expr:
		owning_copy_touch(st, node.x, kill)
		owning_copy_touch(st, node.cond, kill)
		owning_copy_touch(st, node.y, kill)
	case ^ast.Ternary_When_Expr:
		owning_copy_touch(st, node.x, kill)
		owning_copy_touch(st, node.cond, kill)
		owning_copy_touch(st, node.y, kill)
	case ^ast.Type_Assertion:
		owning_copy_touch(st, node.expr, kill)
	case ^ast.Selector_Call_Expr:
		owning_copy_touch(st, node.expr, true)
		if node.call != nil {
			owning_copy_call(st, node.call)
		}
	case:
		owning_copy_kill_all(st)
	}
}

@(private = "file")
owning_copy_call :: proc(st: ^Owning_Copy_State, call: ^ast.Call_Expr) {
	name := owning_copy_callee(call)
	shadowed := name == "" || owning_copy_bound(st, name)
	if !shadowed && owning_copy_delete_name(name) {
		if arg, ok := owning_copy_single_ident(call); ok {
			slot, found := owning_copy_lookup(st, arg)
			if found && owning_copy_live(st, slot.alloc) {
				kind := st.allocs[slot.alloc].kind
				if owning_copy_delete_applies(name, kind) {
					owning_copy_on_delete(st, arg, call.pos.line)
					return
				}
			}
		}
	}
	if !shadowed && (name == "len" || name == "cap") && len(call.args) == 1 {
		owning_copy_touch(st, call.args[0], false)
		return
	}
	if !shadowed && name == "make" {
		for arg, index in call.args {
			if index == 0 && call.args[0].derived_expr != nil {
				if _, named := ast.unparen_expr(arg).derived_expr.(^ast.Field_Value); !named {
					continue
				}
			}
			owning_copy_touch(st, arg, false)
		}
		return
	}
	owning_copy_touch(st, call.expr, true)
	for arg in call.args {
		owning_copy_touch(st, arg, true)
	}
}

@(private = "file")
owning_copy_delete_name :: proc(name: string) -> bool {
	switch name {
	case "delete", "delete_dynamic_array", "delete_map", "delete_soa_dynamic_array":
		return true
	}
	return false
}

@(private = "file")
owning_copy_single_ident :: proc(call: ^ast.Call_Expr) -> (string, bool) {
	if len(call.args) != 1 {
		return "", false
	}
	arg := ast.unparen_expr(call.args[0])
	if field, ok := arg.derived_expr.(^ast.Field_Value); ok {
		arg = ast.unparen_expr(field.value)
	}
	text := owning_copy_ident(arg)
	return text, text != ""
}

@(private = "file")
owning_copy_callee :: proc(call: ^ast.Call_Expr) -> string {
	return owning_copy_ident(ast.strip_or_return_expr(call.expr))
}

@(private = "file")
owning_copy_ident :: proc(expr: ^ast.Expr) -> string {
	if expr == nil {
		return ""
	}
	ident, ok := ast.unparen_expr(expr).derived_expr.(^ast.Ident)
	if !ok {
		return ""
	}
	return ident.name
}

@(private = "file")
owning_copy_make :: proc(st: ^Owning_Copy_State, expr: ^ast.Expr) -> (string, bool) {
	call, ok := expr.derived_expr.(^ast.Call_Expr)
	if !ok {
		return "", false
	}
	name := owning_copy_callee(call)
	if name != "make" || owning_copy_bound(st, name) {
		return "", false
	}
	type_expr: ^ast.Expr
	positionals := make([dynamic]^ast.Expr)
	allocator, length, capacity: ^ast.Expr
	kind := ""
	for arg, index in call.args {
		item := ast.unparen_expr(arg)
		if field, named := item.derived_expr.(^ast.Field_Value); named {
			field_name := owning_copy_ident(field.field)
			switch field_name {
			case "allocator":
				allocator = field.value
			case "loc", "location":
			case "len", "length":
				length = field.value
			case "cap", "capacity":
				capacity = field.value
			case:
				return "", false
			}
			continue
		}
		if index == 0 {
			type_expr = item
		} else {
			append(&positionals, item)
		}
	}
	if type_expr == nil {
		return "", false
	}
	type_expr = ast.unparen_expr(type_expr)
	#partial switch typ in type_expr.derived_expr {
	case ^ast.Dynamic_Array_Type:
		kind = "dynamic array"
		if typ.tag != nil {
			directive, is_directive := typ.tag.derived_expr.(^ast.Basic_Directive)
			if !is_directive || directive.name != "soa" {
				return "", false
			}
			kind = "SOA dynamic array"
		}
		if !owning_copy_nonzero(st, typ.elem) {
			return "", false
		}
	case ^ast.Map_Type:
		kind = "map"
	case:
		return "", false
	}
	if kind == "map" && length != nil {
		return "", false
	}
	if allocator != nil || length != nil || capacity != nil {
		if !owning_copy_heap(st, allocator) {
			return "", false
		}
		if capacity != nil {
			return kind, owning_copy_positive(capacity)
		}
		if kind != "map" && length != nil {
			return kind, owning_copy_positive(length)
		}
		// `make(T, 4, allocator = heap)` keeps the size positional.
		if len(positionals) >= 1 {
			size := positionals[0]
			if kind != "map" && len(positionals) >= 2 {
				size = positionals[1]
			}
			return kind, owning_copy_positive(size)
		}
		return "", false
	}
	switch len(positionals) {
	case 2:
		if owning_copy_heap(st, positionals[1]) && owning_copy_positive(positionals[0]) {
			return kind, true
		}
	case 3:
		if kind == "map" {
			if owning_copy_heap(st, positionals[1]) && owning_copy_positive(positionals[0]) {
				return kind, true
			}
			return "", false
		}
		if owning_copy_heap(st, positionals[1]) && owning_copy_positive(positionals[0]) {
			return kind, true
		}
		if owning_copy_heap(st, positionals[2]) && owning_copy_positive(positionals[1]) {
			return kind, true
		}
	case 4:
		if kind != "map" &&
		   owning_copy_heap(st, positionals[2]) &&
		   owning_copy_positive(positionals[1]) {
			return kind, true
		}
	}
	return "", false
}

@(private = "file")
owning_copy_heap :: proc(st: ^Owning_Copy_State, expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	call, ok := ast.strip_or_return_expr(expr).derived_expr.(^ast.Call_Expr)
	if !ok || len(call.args) != 0 {
		return false
	}
	selector, is_selector := ast.unparen_expr(call.expr).derived_expr.(^ast.Selector_Expr)
	if !is_selector || selector.field == nil || selector.field.name != "heap_allocator" {
		return false
	}
	pkg := owning_copy_ident(selector.expr)
	if pkg == "" {
		return false
	}
	if _, shadows := owning_copy_lookup(st, pkg); shadows {
		return false
	}
	path := st.imports[pkg]
	if path == "" && pkg == "runtime" {
		path = "base:runtime"
	}
	return path == "base:runtime" || path == "core:os"
}

@(private = "file")
owning_copy_positive :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	lit, ok := ast.unparen_expr(expr).derived_expr.(^ast.Basic_Lit)
	if !ok || lit.tok.kind != .Integer {
		return false
	}
	return owning_copy_int(lit.tok.text) > 0
}

@(private = "file")
owning_copy_int :: proc(text: string) -> int {
	bytes := make([dynamic]u8)
	for ch in text {
		if ch != '_' {
			append(&bytes, u8(ch))
		}
	}
	body := string(bytes[:])
	base := 10
	if len(body) >= 2 && body[0] == '0' {
		switch body[1] {
		case 'x', 'X':
			base = 16
			body = body[2:]
		case 'b', 'B':
			base = 2
			body = body[2:]
		case 'o', 'O':
			base = 8
			body = body[2:]
		case 'd', 'D':
			base = 10
			body = body[2:]
		case 'z', 'Z':
			return 0
		}
	}
	value, ok := strconv.parse_int(body, base)
	if !ok || value <= 0 {
		return 0
	}
	return value
}

@(private = "file")
owning_copy_nonzero :: proc(st: ^Owning_Copy_State, expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	#partial switch node in ast.unparen_expr(expr).derived_expr {
	case ^ast.Ident:
		return st.nonzero[node.name]
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type:
		return true
	case ^ast.Array_Type:
		if node.len == nil {
			return true
		}
		return owning_copy_positive(node.len) && owning_copy_nonzero(st, node.elem)
	case ^ast.Struct_Type:
		if node.fields == nil {
			return false
		}
		for field in node.fields.list {
			if owning_copy_nonzero(st, field.type) {
				return true
			}
		}
		return false
	}
	return false
}

@(private = "file")
owning_copy_builtins :: proc() -> map[string]bool {
	names := []string {
		"bool", "b8", "b16", "b32", "b64",
		"i8", "i16", "i32", "i64", "i128", "int",
		"u8", "u16", "u32", "u64", "u128", "uint", "uintptr",
		"byte", "rune",
		"f16", "f32", "f64",
		"complex32", "complex64", "complex128",
		"string", "cstring", "rawptr", "typeid",
	}
	out := make(map[string]bool)
	for name in names {
		out[name] = true
	}
	return out
}
