package check

// Types and helpers for the container-invalidation walk. The walker is a
// separate file. Nothing here walks a procedure body.

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:strconv"
import "core:strings"

import "../finding"

@(private = "file")
container_invalidation_growth_names := []string {
	"append",
	"non_zero_append",
	"append_nothing",
	"reserve",
	"non_zero_reserve",
	"resize",
	"non_zero_resize",
	"inject_at",
}

@(private = "file")
container_invalidation_len_names := []string {
	"clear",
	"pop",
	"pop_safe",
	"pop_front",
	"pop_front_safe",
	"ordered_remove",
	"unordered_remove",
	"remove_range",
}

@(private = "file")
container_invalidation_other_names := []string {
	"make",
	"raw_data",
	"false",
	"true",
}


// Container_Invalidation_Halt stops a straight-line walk. Break ends the
// enclosing block's remainder; Return ends the procedure.
@(private)
Container_Invalidation_Halt :: enum {
	None,
	Break,
	Return,
}

@(private)
Container_Invalidation_Storage :: struct {
	epoch:     int,
	died:      int,
	died_op:   string,
	touch:     int,
	touch_op:  string,
	elem_zero: bool,
	elem_byte: bool,
}

@(private)
Container_Invalidation_Header :: struct {
	storage:     int,
	epoch:       int,
	indirect:    bool,
	len_bounded: bool,
	len_exact:   bool,
	len:         int,
	cap_known:   bool,
	cap_at_least: int,
}

@(private)
Container_Invalidation_Borrow :: struct {
	storage: int,
	epoch:   int,
	line:    int,
	died:    int,
	died_op: string,
	array:   string,
}

@(private)
Container_Invalidation_Undo_Kind :: enum {
	Header,
	Borrow,
	Alias,
	Const,
	Type,
	Shadow,
}

@(private)
Container_Invalidation_Undo :: struct {
	kind:    Container_Invalidation_Undo_Kind,
	name:    string,
	had:     bool,
	header:  Container_Invalidation_Header,
	borrow:  Container_Invalidation_Borrow,
	alias:   string,
	num:     int,
	typ:     ^ast.Expr,
}

@(private)
Container_Invalidation_Frame :: struct {
	noted: map[string]bool,
	undo:  [dynamic]Container_Invalidation_Undo,
}

@(private)
Container_Invalidation_State :: struct {
	storages:   [dynamic]Container_Invalidation_Storage,
	headers:    map[string]Container_Invalidation_Header,
	borrows:    map[string]Container_Invalidation_Borrow,
	// Addresses can be taken before a variable holds a borrow. Retain that
	// fact so later indirect writes discard any borrow assigned in between.
	addressed:  map[string]bool,
	aliases:    map[string]string,
	consts:     map[string]int,
	types:      map[string]^ast.Expr,
	shadow:     map[string]int,
	halt:       Container_Invalidation_Halt,
	repeating:  bool,
	// observe is set while a call's result is bound. A failed append,
	// reserve, or resize can leave the old pointer valid, and this pass
	// does not separate that path, so the call is not proof of a move.
	observe:    bool,
	file_base:  ^Container_Invalidation_State,
	added:      map[int]bool,
	path:       string,
	out:        ^[dynamic]finding.Finding,
	keep:       runtime.Allocator,
	reported:   map[int]bool,
}

@(private)
Container_Invalidation_Scan :: struct {
	ok:    bool,
	exact: bool,
	// resets is a clear, pop, or remove in the iteration. The length is not
	// a straight multiple of the appends, so the loop is simulated.
	resets: bool,
	// added counts elements appended to one storage during one iteration.
	added:  map[int]int,
}

@(private)
Container_Invalidation_Kind :: enum {
	None,
	Borrow,
	Alias,
	Header,
}

@(private)
Container_Invalidation_Spec :: struct {
	kind:   Container_Invalidation_Kind,
	borrow: Container_Invalidation_Borrow,
	alias:  string,
	header: Container_Invalidation_Header,
}

@(private)
container_invalidation_state :: proc(
	path: string,
	added: map[int]bool,
	out: ^[dynamic]finding.Finding,
	keep: runtime.Allocator,
) -> Container_Invalidation_State {
	s := Container_Invalidation_State {
		headers  = make(map[string]Container_Invalidation_Header, context.temp_allocator),
		borrows   = make(map[string]Container_Invalidation_Borrow, context.temp_allocator),
		addressed = make(map[string]bool, context.temp_allocator),
		aliases   = make(map[string]string, context.temp_allocator),
		consts   = make(map[string]int, context.temp_allocator),
		types    = make(map[string]^ast.Expr, context.temp_allocator),
		shadow   = make(map[string]int, context.temp_allocator),
		added    = added,
		path     = path,
		out      = out,
		keep     = keep,
		reported = make(map[int]bool, context.temp_allocator),
	}
	s.storages = make([dynamic]Container_Invalidation_Storage, context.temp_allocator)
	return s
}

@(private)
container_invalidation_clone :: proc(
	s: ^Container_Invalidation_State,
) -> Container_Invalidation_State {
	c := container_invalidation_state(s.path, s.added, s.out, s.keep)
	c.reported = s.reported
	c.file_base = s.file_base
	c.halt = s.halt
	c.repeating = s.repeating
	c.observe = s.observe
	c.storages = make([dynamic]Container_Invalidation_Storage, context.temp_allocator)
	for st in s.storages {
		append(&c.storages, st)
	}
	for name, header in s.headers {
		c.headers[name] = header
	}
	for name, borrow in s.borrows {
		c.borrows[name] = borrow
	}
	for name, taken in s.addressed {
		if taken {
			c.addressed[name] = true
		}
	}
	for name, alias in s.aliases {
		c.aliases[name] = alias
	}
	for name, n in s.consts {
		c.consts[name] = n
	}
	for name, typ in s.types {
		c.types[name] = typ
	}
	for name, n in s.shadow {
		c.shadow[name] = n
	}
	return c
}

@(private)
container_invalidation_moves :: proc(
	s: ^Container_Invalidation_State,
	header: Container_Invalidation_Header,
	name: string,
	n: ^ast.Call_Expr,
	delta: int,
	delta_known: bool,
) -> bool {
	name := name
	delta := delta
	st := s.storages[header.storage]
	// A zero-sized element has no backing store for a pointer to chase.
	if st.elem_zero {
		return false
	}
	synced := header.epoch == st.epoch
	room := synced && header.cap_known && header.len_bounded
	switch name {
	case "append_nothing":
		return !(room && header.len + 1 <= header.cap_at_least)
	case "append", "non_zero_append":
		if !delta_known {
			return true
		}
		if delta <= 0 {
			return false
		}
		return !(room && header.len + delta <= header.cap_at_least)
	case "reserve", "non_zero_reserve":
		num, known := container_invalidation_int(s, container_invalidation_arg(n, 1, "capacity"))
		if known && synced && header.cap_known && num <= header.cap_at_least {
			return false
		}
		return true
	case "resize", "non_zero_resize":
		num, known := container_invalidation_int(s, container_invalidation_arg(n, 1, "length"))
		if known && synced && header.cap_known && num <= header.cap_at_least {
			return false
		}
		return true
	case "inject_at":
		if !delta_known || delta <= 0 {
			return delta > 0 || !delta_known
		}
		index, index_known := container_invalidation_int(s, container_invalidation_arg(n, 1, "index"))
		if !room {
			return true
		}
		need := header.len + delta
		if index_known && header.len_exact && index > header.len {
			need = index + delta
		} else if !index_known || !header.len_exact {
			return true
		}
		return need > header.cap_at_least
	}
	return true
}

@(private)
container_invalidation_move :: proc(
	s: ^Container_Invalidation_State,
	name: string,
	line: int,
	op: string,
) {
	name := name
	header, ok := s.headers[name]
	if !ok {
		return
	}
	st := s.storages[header.storage]
	old := st.epoch
	if st.died == 0 {
		st.died = line
		st.died_op = op
	}
	st.epoch += 1
	s.storages[header.storage] = st
	header.epoch = st.epoch
	s.headers[name] = header
	names := make([dynamic]string, context.temp_allocator)
	for borrow_name, borrow in s.borrows {
		if borrow.storage == header.storage && borrow.epoch == old && borrow.died == 0 {
			append(&names, borrow_name)
		}
	}
	for borrow_name in names {
		borrow := s.borrows[borrow_name]
		borrow.died = line
		borrow.died_op = op
		s.borrows[borrow_name] = borrow
	}
}

@(private)
container_invalidation_delta :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Call_Expr,
	name: string,
	elem_byte: bool,
) -> (delta: int, known: bool) {
	name := name
	if name == "append_nothing" {
		return 1, true
	}
	if name != "append" && name != "non_zero_append" && name != "inject_at" {
		return 0, true
	}
	start := 1
	if name == "inject_at" {
		start = 2
	}
	if n.ellipsis.kind == .Ellipsis {
		return 0, false
	}
	if len(n.args) <= start {
		return 0, true
	}
	delta = 0
	for i in start ..< len(n.args) {
		arg := container_invalidation_value_arg(n.args[i])
		if elem_byte {
			if lit, ok := container_invalidation_unparen(arg).derived_expr.(^ast.Basic_Lit);
			   ok && lit.tok.kind == .String {
				n, exact := container_invalidation_string_bound(lit.tok.text)
				if !exact {
					return 0, false
				}
				delta += n
				continue
			}
			return 0, false
		}
		delta += 1
	}
	return delta, true
}

@(private = "file")
container_invalidation_string_bound :: proc(text: string) -> (n: int, ok: bool) {
	if len(text) < 2 || (text[0] != '"' && text[0] != '`') {
		return 0, false
	}
	body := text[1:len(text) - 1]
	// An escape is shorter than its source spelling. The exact byte count
	// is then unknown, so the caller must not treat the append as proven.
	if strings.contains(body, "\\") {
		return 0, false
	}
	return len(body), true
}

@(private)
container_invalidation_growth_header :: proc(
	s: ^Container_Invalidation_State,
	n: ^ast.Call_Expr,
) -> (name: string, header: Container_Invalidation_Header, ok: bool) {
	arg := container_invalidation_arg(n, 0, "array")
	arg = container_invalidation_unparen(arg)
	if arg == nil {
		return
	}
	if unary, is_unary := arg.derived_expr.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
		name = container_invalidation_ident(unary.expr)
		header, ok = s.headers[name]
		if ok && !header.indirect {
			return
		}
		return "", {}, false
	}
	if id := container_invalidation_ident(arg); id != "" {
		if alias, is_alias := s.aliases[id]; is_alias {
			name = alias
			header, ok = s.headers[name]
			return
		}
		header, ok = s.headers[id]
		if ok && header.indirect {
			name = id
			return
		}
	}
	return "", {}, false
}

@(private)
container_invalidation_classify :: proc(
	s: ^Container_Invalidation_State,
	typ, value: ^ast.Expr,
	line: int,
) -> (spec: Container_Invalidation_Spec) {
	value := value
	line := line
	if ref, ok := container_invalidation_borrow_expr(s, value); ok {
		// A copy of an existing reference keeps that reference's epoch.
		// Overwriting it with the current epoch would resurrect a dead one.
		if ref.line == 0 {
			ref.line = line
		}
		return Container_Invalidation_Spec{kind = .Borrow, borrow = ref}
	}
	if value != nil {
		if unary, is_unary := container_invalidation_unparen(value).derived_expr.(^ast.Unary_Expr);
		   is_unary && unary.op.kind == .And {
			target := container_invalidation_ident(unary.expr)
			if header, is_header := s.headers[target]; is_header && !header.indirect {
				return Container_Invalidation_Spec{kind = .Alias, alias = target}
			}
		}
	}
	if other := container_invalidation_ident(value); other != "" {
		if header, is_header := s.headers[other]; is_header && !header.indirect {
			return Container_Invalidation_Spec{kind = .Header, header = header}
		}
	}
	info := container_invalidation_dyn(s, typ)
	if value != nil {
		if made := container_invalidation_make_type(s, value); made != nil {
			info = made
		} else if lit := container_invalidation_comp_type(s, value); lit != nil {
			info = lit
		}
	}
	if info == nil {
		return
	}
	id := container_invalidation_storage(s, info)
	header := Container_Invalidation_Header {
		storage = id,
		epoch   = s.storages[id].epoch,
	}
	if facts, known := container_invalidation_make_facts(s, value); known {
		// len is an upper bound only when the count itself is known.
		// An unknown length of 0 would make every later append look safe.
		header.len_bounded = facts.len_exact
		header.len_exact = facts.len_exact
		header.len = facts.len
		header.cap_known = facts.cap_known
		header.cap_at_least = facts.cap
	} else if value == nil || container_invalidation_is_nil(s, value) {
		header.len_bounded = true
		header.len_exact = true
		header.cap_known = true
	}
	return Container_Invalidation_Spec{kind = .Header, header = header}
}

@(private)
container_invalidation_install :: proc(
	s: ^Container_Invalidation_State,
	name: string,
	spec: Container_Invalidation_Spec,
) {
	switch spec.kind {
	case .None:
	case .Borrow:
		s.borrows[name] = spec.borrow
	case .Alias:
		s.aliases[name] = spec.alias
	case .Header:
		s.headers[name] = spec.header
	}
}

@(private = "file")
container_invalidation_is_nil :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> bool {
	name := container_invalidation_ident(e)
	return name == "nil" && !container_invalidation_shadowed(s, name)
}

@(private = "file")
container_invalidation_comp_type :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> ^ast.Expr {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return nil
	}
	lit, ok := e.derived_expr.(^ast.Comp_Lit)
	if !ok {
		return nil
	}
	return container_invalidation_dyn(s, lit.type)
}

@(private)
Container_Invalidation_Facts :: struct {
	len:       int,
	len_exact: bool,
	cap:       int,
	cap_known: bool,
}

@(private = "file")
container_invalidation_make_facts :: proc(
	s: ^Container_Invalidation_State,
	value: ^ast.Expr,
) -> (facts: Container_Invalidation_Facts, ok: bool) {
	value := value
	value = container_invalidation_unparen(value)
	if value == nil {
		return
	}
	#partial switch n in value.derived_expr {
	case ^ast.Call_Expr:
		if container_invalidation_ident(n.expr) != "make" || container_invalidation_shadowed(s, "make") {
			return
		}
		if container_invalidation_make_type(s, value) == nil {
			return
		}
		ok = true
		facts.len_exact = true
		facts.cap_known = true
		positional := make([dynamic]^ast.Expr, context.temp_allocator)
		len_set, cap_set := false, false
		for i in 1 ..< len(n.args) {
			arg := n.args[i]
			if field, is_field := arg.derived_expr.(^ast.Field_Value); is_field {
				switch container_invalidation_ident(field.field) {
				case "len":
					if num, known := container_invalidation_int(s, field.value); known {
						facts.len = num
						len_set = true
					} else {
						facts.len_exact = false
					}
				case "cap":
					if num, known := container_invalidation_int(s, field.value); known {
						facts.cap = num
						cap_set = true
					} else {
						facts.cap_known = false
					}
				case "allocator", "loc":
				case:
					return {}, false
				}
				continue
			}
			append(&positional, arg)
		}
		if !len_set && len(positional) >= 1 {
			if num, known := container_invalidation_int(s, positional[0]); known {
				facts.len = num
				len_set = true
			} else {
				facts.len_exact = false
			}
		}
		if !cap_set && len(positional) >= 2 {
			if num, known := container_invalidation_int(s, positional[1]); known {
				facts.cap = num
				cap_set = true
			} else {
				facts.cap_known = false
			}
		}
		if len(positional) > 3 {
			return {}, false
		}
		if !cap_set && facts.cap_known {
			if facts.len_exact {
				facts.cap = facts.len
			} else {
				facts.cap_known = false
			}
		}
	case ^ast.Comp_Lit:
		if container_invalidation_dyn(s, n.type) == nil {
			return
		}
		ok = true
		facts.cap_known = true
		facts.len_exact = true
		highest := 0
		for elem, i in n.elems {
			item := container_invalidation_unparen(elem)
			if item == nil {
				facts.len_exact = false
				facts.cap_known = false
				return
			}
			if _, spread := item.derived_expr.(^ast.Ellipsis); spread {
				facts.len_exact = false
				facts.cap_known = false
				return
			}
			if field, keyed := item.derived_expr.(^ast.Field_Value); keyed {
				if num, known := container_invalidation_int(s, field.field); known {
					highest = max(highest, num + 1)
				} else {
					facts.len_exact = false
					facts.cap_known = false
					return
				}
				continue
			}
			highest = max(highest, i + 1)
		}
		facts.len = highest
		facts.cap = highest
	}
	return
}

@(private = "file")
container_invalidation_borrow_expr :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
) -> (ref: Container_Invalidation_Borrow, ok: bool) {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return
	}
	#partial switch n in e.derived_expr {
	case ^ast.Ident:
		ref, ok = s.borrows[n.name]
	case ^ast.Paren_Expr:
		return container_invalidation_borrow_expr(s, n.expr)
	case ^ast.Type_Cast:
		return container_invalidation_borrow_expr(s, n.expr)
	case ^ast.Auto_Cast:
		return container_invalidation_borrow_expr(s, n.expr)
	case ^ast.Unary_Expr:
		if n.op.kind != .And {
			return
		}
		inner := container_invalidation_skip_field(n.expr)
		index, is_index := inner.derived_expr.(^ast.Index_Expr)
		if !is_index {
			return
		}
		if storage, found := container_invalidation_storage_of_expr(s, index.expr); found {
			ref = {
				storage = storage,
				epoch   = s.storages[storage].epoch,
				line    = e.pos.line,
				array   = container_invalidation_array_name(s, index.expr, storage),
			}
			ok = true
		}
	case ^ast.Slice_Expr:
		if storage, found := container_invalidation_storage_of_expr(s, n.expr); found {
			ref = {
				storage = storage,
				epoch   = s.storages[storage].epoch,
				line    = e.pos.line,
				array   = container_invalidation_array_name(s, n.expr, storage),
			}
			ok = true
		}
	case ^ast.Call_Expr:
		if container_invalidation_ident(n.expr) != "raw_data" ||
		   container_invalidation_shadowed(s, "raw_data") ||
		   len(n.args) < 1 {
			return
		}
		arg := container_invalidation_value_arg(n.args[0])
		if storage, found := container_invalidation_storage_of_expr(s, arg); found {
			ref = {
				storage = storage,
				epoch   = s.storages[storage].epoch,
				line    = e.pos.line,
				array   = container_invalidation_array_name(s, arg, storage),
			}
			ok = true
		}
	}
	return
}

@(private)
container_invalidation_array_name :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
	storage: int,
) -> string {
	e := e
	e = container_invalidation_skip_deref(s, container_invalidation_unparen(e))
	if e == nil {
		return container_invalidation_header_name(s, storage)
	}
	if id := container_invalidation_ident(e); id != "" {
		if alias, is_alias := s.aliases[id]; is_alias {
			return alias
		}
		if _, is_header := s.headers[id]; is_header {
			return id
		}
		if borrow, is_borrow := s.borrows[id]; is_borrow && borrow.array != "" {
			return borrow.array
		}
		return id
	}
	#partial switch n in e.derived_expr {
	case ^ast.Slice_Expr:
		return container_invalidation_array_name(s, n.expr, storage)
	case ^ast.Index_Expr:
		return container_invalidation_array_name(s, n.expr, storage)
	case ^ast.Unary_Expr:
		if n.op.kind == .And {
			return container_invalidation_array_name(s, n.expr, storage)
		}
	}
	return container_invalidation_header_name(s, storage)
}

@(private)
container_invalidation_storage_of_expr :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
) -> (storage: int, ok: bool) {
	e := e
	e = container_invalidation_skip_deref(s, container_invalidation_unparen(e))
	if e == nil {
		return
	}
	if id := container_invalidation_ident(e); id != "" {
		if alias, is_alias := s.aliases[id]; is_alias {
			if header, is_header := s.headers[alias]; is_header {
				return header.storage, true
			}
		}
		if header, is_header := s.headers[id]; is_header {
			return header.storage, true
		}
		if borrow, is_borrow := s.borrows[id]; is_borrow {
			return borrow.storage, true
		}
	}
	#partial switch n in e.derived_expr {
	case ^ast.Slice_Expr:
		return container_invalidation_storage_of_expr(s, n.expr)
	case ^ast.Unary_Expr:
		if n.op.kind == .And {
			return container_invalidation_storage_of_expr(s, n.expr)
		}
	case ^ast.Index_Expr:
		return container_invalidation_storage_of_expr(s, n.expr)
	}
	return
}

@(private)
container_invalidation_report :: proc(
	s: ^Container_Invalidation_State,
	borrow, array, op: string,
	use_line, died, born: int,
) {
	array := array
	op := op
	line := 0
	if s.added[use_line] {
		line = use_line
	} else if died != 0 && s.added[died] {
		line = died
	} else if born != 0 && s.added[born] {
		line = born
	}
	if line == 0 || s.reported[line] {
		return
	}
	s.reported[line] = true
	if op == "" {
		op = "a growth call"
	}
	if array == "" {
		array = borrow
	}
	append(
		s.out,
		static(
			"odin-container-invalidation",
			.Must_Fix,
			fmt.aprintf(
				"`%s` points into `%s` and is used after `%s` may reallocate it",
				borrow,
				array,
				op,
				allocator = s.keep,
			),
			"reserve enough capacity before the reference is taken, or form the pointer or slice again after the growth",
			file = s.path,
			line = line,
		),
	)
}

@(private)
container_invalidation_header_name :: proc(s: ^Container_Invalidation_State, storage: int) -> string {
	for name, header in s.headers {
		if header.storage == storage {
			return name
		}
	}
	return ""
}

@(private)
container_invalidation_note_len :: proc(
	s: ^Container_Invalidation_State,
	name: string,
	delta: int,
	up: bool,
) {
	header, ok := s.headers[name]
	if !ok || delta == 0 {
		return
	}
	if header.epoch != s.storages[header.storage].epoch || !header.len_bounded {
		return
	}
	if up {
		header.len += delta
	} else if header.len_exact {
		header.len = max(0, header.len - delta)
	}
	s.headers[name] = header
}

@(private)
container_invalidation_set_len :: proc(s: ^Container_Invalidation_State, name: string, len: int) {
	header, ok := s.headers[name]
	if !ok || header.epoch != s.storages[header.storage].epoch {
		return
	}
	header.len = len
	header.len_bounded = true
	header.len_exact = true
	s.headers[name] = header
}

@(private)
container_invalidation_forget_len :: proc(s: ^Container_Invalidation_State, name: string) {
	header, ok := s.headers[name]
	if !ok {
		return
	}
	header.len_bounded = false
	header.len_exact = false
	s.headers[name] = header
}

@(private)
container_invalidation_note_cap :: proc(s: ^Container_Invalidation_State, name: string, cap: int) {
	header, ok := s.headers[name]
	if !ok || header.epoch != s.storages[header.storage].epoch {
		return
	}
	if !header.cap_known || cap > header.cap_at_least {
		header.cap_at_least = cap
	}
	header.cap_known = true
	s.headers[name] = header
}

@(private)
container_invalidation_forget_cap :: proc(s: ^Container_Invalidation_State, name: string) {
	header, ok := s.headers[name]
	if !ok {
		return
	}
	header.cap_known = false
	s.headers[name] = header
}

@(private)
Container_Invalidation_Len_Snap :: struct {
	name:        string,
	len:         int,
	len_bounded: bool,
	len_exact:   bool,
}

@(private)
container_invalidation_len_snapshot :: proc(
	s: ^Container_Invalidation_State,
) -> [dynamic]Container_Invalidation_Len_Snap {
	out := make([dynamic]Container_Invalidation_Len_Snap, context.temp_allocator)
	for name, header in s.headers {
		append(&out, Container_Invalidation_Len_Snap{name, header.len, header.len_bounded, header.len_exact})
	}
	return out
}

@(private)
container_invalidation_apply_added :: proc(
	s: ^Container_Invalidation_State,
	snap: [dynamic]Container_Invalidation_Len_Snap,
	scan: Container_Invalidation_Scan,
	times: int,
) {
	if !scan.ok || times < 0 {
		return
	}
	for item in snap {
		header, ok := s.headers[item.name]
		if !ok || !item.len_bounded || header.storage < 0 || header.storage >= len(s.storages) {
			continue
		}
		if header.epoch != s.storages[header.storage].epoch {
			continue
		}
		count := 0
		if scan.added != nil {
			count = scan.added[header.storage]
		}
		header.len = item.len + count * times
		header.len_bounded = true
		header.len_exact = item.len_exact && scan.exact
		s.headers[item.name] = header
	}
}

@(private)
container_invalidation_loop_fits :: proc(
	s: ^Container_Invalidation_State,
	scan: Container_Invalidation_Scan,
	trips_known: bool,
	trips: int,
) -> bool {
	if !scan.ok {
		return false
	}
	for id, count in scan.added {
		if count <= 0 {
			continue
		}
		if id < 0 || id >= len(s.storages) {
			return false
		}
		if s.storages[id].elem_zero {
			continue
		}
		if !trips_known || !container_invalidation_storage_room(s, id, count * trips) {
			return false
		}
	}
	return true
}

@(private = "file")
container_invalidation_storage_room :: proc(
	s: ^Container_Invalidation_State,
	id, extra: int,
) -> bool {
	saw := false
	for _, header in s.headers {
		if header.storage != id {
			continue
		}
		saw = true
		if header.epoch != s.storages[id].epoch || !header.cap_known || !header.len_bounded {
			return false
		}
		if header.len + extra > header.cap_at_least {
			return false
		}
	}
	return saw
}

@(private)
container_invalidation_scan_new :: proc() -> Container_Invalidation_Scan {
	return {
		ok = true,
		exact = true,
		added = make(map[int]int, context.temp_allocator),
	}
}

@(private)
container_invalidation_project :: proc(
	s: ^Container_Invalidation_State,
	entry: [dynamic]Container_Invalidation_Len_Snap,
	trips: int,
	trips_known: bool,
) {
	for item in entry {
		header, ok := s.headers[item.name]
		if !ok || header.storage < 0 || header.storage >= len(s.storages) {
			continue
		}
		st := s.storages[header.storage]
		if header.epoch != st.epoch || st.touch == 0 {
			continue
		}
		if !item.len_bounded || !header.len_bounded || !header.cap_known {
			container_invalidation_move(s, item.name, st.touch, st.touch_op)
			continue
		}
		net := header.len - item.len
		if net <= 0 {
			continue
		}
		over := !trips_known || item.len + net * trips > header.cap_at_least
		if over {
			container_invalidation_move(s, item.name, st.touch, st.touch_op)
		}
	}
}

@(private)
container_invalidation_scan_max :: proc(
	a, b: Container_Invalidation_Scan,
) -> Container_Invalidation_Scan {
	out := container_invalidation_scan_new()
	out.exact = false
	seen := make(map[int]bool, context.temp_allocator)
	for id in a.added {
		seen[id] = true
	}
	for id in b.added {
		seen[id] = true
	}
	for id in seen {
		out.added[id] = max(a.added[id], b.added[id])
	}
	out.resets = a.resets || b.resets
	return out
}

@(private)
container_invalidation_scan_add :: proc(
	dst: ^Container_Invalidation_Scan,
	extra: Container_Invalidation_Scan,
) {
	if dst.added == nil {
		dst.added = make(map[int]int, context.temp_allocator)
	}
	for id, count in extra.added {
		dst.added[id] += count
	}
	dst.resets = dst.resets || extra.resets
}

@(private)
container_invalidation_join :: proc(
	dst, a, b: ^Container_Invalidation_State,
) {
	// Copy the descriptors first. Switch joins into its accumulator, so dst
	// and a can be the same state; writing dst must not destroy a.
	aa := a^
	bb := b^
	limit := min(len(aa.storages), len(bb.storages))
	dst.storages = make([dynamic]Container_Invalidation_Storage, context.temp_allocator)
	for i in 0 ..< limit {
		st := aa.storages[i]
		if bb.storages[i].epoch > st.epoch {
			st = bb.storages[i]
		}
		append(&dst.storages, st)
	}
	dst.headers = make(map[string]Container_Invalidation_Header, context.temp_allocator)
	for name, left in aa.headers {
		left := left
		right, in_b := bb.headers[name]
		if !in_b || left.storage != right.storage || left.storage >= limit {
			continue
		}
		synced_a := left.epoch == aa.storages[left.storage].epoch
		synced_b := right.epoch == bb.storages[right.storage].epoch
		left.epoch = dst.storages[left.storage].epoch
		if !synced_a || !synced_b {
			// Stale on a path that reaches here. A later index is a use.
			left.len_bounded = false
			left.len_exact = false
			left.cap_known = false
			left.epoch -= 1
			dst.headers[name] = left
			continue
		}
		if aa.storages[left.storage].epoch != bb.storages[left.storage].epoch {
			left.len_bounded = false
			left.len_exact = false
			left.cap_known = false
			dst.headers[name] = left
			continue
		}
		if left.len_bounded && right.len_bounded {
			left.len_exact = left.len_exact && right.len_exact && left.len == right.len
			left.len = max(left.len, right.len)
		} else {
			left.len_bounded = false
			left.len_exact = false
		}
		if left.cap_known && right.cap_known {
			left.cap_at_least = min(left.cap_at_least, right.cap_at_least)
		} else {
			left.cap_known = false
		}
		dst.headers[name] = left
	}
	dst.borrows = make(map[string]Container_Invalidation_Borrow, context.temp_allocator)
	for name, left in aa.borrows {
		left := left
		right, in_b := bb.borrows[name]
		if !in_b || left.storage != right.storage || left.storage >= limit {
			continue
		}
		st := dst.storages[left.storage]
		alive_a := left.died == 0 && left.epoch == aa.storages[left.storage].epoch
		alive_b := right.died == 0 && right.epoch == bb.storages[right.storage].epoch
		if alive_a && alive_b {
			// Alive on both paths, including when one path moved and took
			// the reference again. The epochs need not match.
			left.died = 0
			left.died_op = ""
			left.epoch = st.epoch
			dst.borrows[name] = left
			continue
		}
		if left.died == 0 {
			left.died = right.died
			left.died_op = right.died_op
		}
		if left.died == 0 {
			left.died = st.died
			left.died_op = st.died_op
		}
		left.epoch = st.epoch - 1
		dst.borrows[name] = left
	}
	dst.addressed = make(map[string]bool, context.temp_allocator)
	for name, taken in aa.addressed {
		dst.addressed[name] = taken
	}
	for name, taken in bb.addressed {
		dst.addressed[name] ||= taken
	}
	dst.aliases = make(map[string]string, context.temp_allocator)
	for name, alias in aa.aliases {
		if bb.aliases[name] == alias {
			dst.aliases[name] = alias
		}
	}
	if aa.halt == .Return && bb.halt == .Return {
		dst.halt = .Return
	} else if aa.halt == .Break && bb.halt == .Break {
		dst.halt = .Break
	} else {
		dst.halt = .None
	}
}

@(private)
container_invalidation_replace :: proc(
	dst, src: ^Container_Invalidation_State,
) {
	dst.storages = src.storages
	dst.headers = src.headers
	dst.borrows = src.borrows
	dst.addressed = src.addressed
	dst.aliases = src.aliases
	dst.consts = src.consts
	dst.types = src.types
	dst.shadow = src.shadow
	dst.halt = src.halt
	dst.repeating = src.repeating
}

@(private)
container_invalidation_frame :: proc() -> Container_Invalidation_Frame {
	return {
		noted = make(map[string]bool, context.temp_allocator),
		undo = make([dynamic]Container_Invalidation_Undo, context.temp_allocator),
	}
}

@(private)
container_invalidation_note :: proc(
	s: ^Container_Invalidation_State,
	frame: ^Container_Invalidation_Frame,
	name: string,
) {
	if frame == nil || name == "" || name in frame.noted {
		return
	}
	frame.noted[name] = true
	header, had_header := s.headers[name]
	append(&frame.undo, Container_Invalidation_Undo{kind = .Header, name = name, had = had_header, header = header})
	borrow, had_borrow := s.borrows[name]
	append(&frame.undo, Container_Invalidation_Undo{kind = .Borrow, name = name, had = had_borrow, borrow = borrow})
	alias, had_alias := s.aliases[name]
	append(&frame.undo, Container_Invalidation_Undo{kind = .Alias, name = name, had = had_alias, alias = alias})
	num, had_const := s.consts[name]
	append(&frame.undo, Container_Invalidation_Undo{kind = .Const, name = name, had = had_const, num = num})
	typ, had_type := s.types[name]
	append(&frame.undo, Container_Invalidation_Undo{kind = .Type, name = name, had = had_type, typ = typ})
	append(&frame.undo, Container_Invalidation_Undo{kind = .Shadow, name = name, had = true, num = s.shadow[name]})
}

@(private)
container_invalidation_frame_pop :: proc(
	s: ^Container_Invalidation_State,
	frame: ^Container_Invalidation_Frame,
) {
	if frame == nil {
		return
	}
	for i := len(frame.undo) - 1; i >= 0; i -= 1 {
		undo := frame.undo[i]
		switch undo.kind {
		case .Header:
			if undo.had {
				s.headers[undo.name] = undo.header
			} else {
				delete_key(&s.headers, undo.name)
			}
		case .Borrow:
			if undo.had {
				s.borrows[undo.name] = undo.borrow
			} else {
				delete_key(&s.borrows, undo.name)
			}
		case .Alias:
			if undo.had {
				s.aliases[undo.name] = undo.alias
			} else {
				delete_key(&s.aliases, undo.name)
			}
		case .Const:
			if undo.had {
				s.consts[undo.name] = undo.num
			} else {
				delete_key(&s.consts, undo.name)
			}
		case .Type:
			if undo.had {
				s.types[undo.name] = undo.typ
			} else {
				delete_key(&s.types, undo.name)
			}
		case .Shadow:
			if undo.num == 0 {
				delete_key(&s.shadow, undo.name)
			} else {
				s.shadow[undo.name] = undo.num
			}
		}
	}
}

@(private)
container_invalidation_clear_binding :: proc(s: ^Container_Invalidation_State, name: string) {
	delete_key(&s.headers, name)
	delete_key(&s.borrows, name)
	delete_key(&s.aliases, name)
	delete_key(&s.consts, name)
	delete_key(&s.types, name)
}

@(private)
container_invalidation_storage :: proc(
	s: ^Container_Invalidation_State,
	info: ^ast.Expr,
) -> int {
	elem := container_invalidation_elem(info)
	id := len(s.storages)
	append(&s.storages, Container_Invalidation_Storage{
		elem_zero = container_invalidation_is_zero_sized(s, elem, 0),
		elem_byte = container_invalidation_is_byte(s, elem),
	})
	return id
}

@(private)
container_invalidation_dyn :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> ^ast.Expr {
	e := e
	e = container_invalidation_resolve(s, e, 0)
	if e == nil {
		return nil
	}
	#partial switch n in e.derived_expr {
	case ^ast.Dynamic_Array_Type:
		return e
	case ^ast.Helper_Type:
		return container_invalidation_dyn(s, n.type)
	}
	return nil
}

@(private)
container_invalidation_make_type :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> ^ast.Expr {
	call, ok := container_invalidation_unparen(e).derived_expr.(^ast.Call_Expr)
	if !ok || len(call.args) < 1 {
		return nil
	}
	if container_invalidation_ident(call.expr) != "make" || container_invalidation_shadowed(s, "make") {
		return nil
	}
	return container_invalidation_dyn(s, call.args[0])
}

@(private = "file")
container_invalidation_elem :: proc(e: ^ast.Expr) -> ^ast.Expr {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return nil
	}
	#partial switch n in e.derived_expr {
	case ^ast.Dynamic_Array_Type:
		return n.elem
	}
	return nil
}

@(private = "file")
container_invalidation_resolve :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
	depth: int,
) -> ^ast.Expr {
	e := e
	if e == nil || depth > 8 {
		return e
	}
	e = container_invalidation_unparen(e)
	if id := container_invalidation_ident(e); id != "" {
		if typ, ok := s.types[id]; ok {
			return container_invalidation_resolve(s, typ, depth + 1)
		}
	}
	return e
}

@(private = "file")
container_invalidation_is_zero_sized :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr, depth: int) -> bool {
	e := e
	if e == nil || depth > 8 {
		return false
	}
	e = container_invalidation_resolve(s, e, 0)
	if e == nil {
		return false
	}
	#partial switch n in e.derived_expr {
	case ^ast.Struct_Type:
		if n.fields == nil {
			return true
		}
		for field in n.fields.list {
			if !container_invalidation_is_zero_sized(s, field.type, depth + 1) {
				return false
			}
		}
		return true
	case ^ast.Array_Type:
		num, known := container_invalidation_int(s, n.len)
		return known && num == 0
	case ^ast.Helper_Type:
		return container_invalidation_is_zero_sized(s, n.type, depth + 1)
	case ^ast.Distinct_Type:
		return container_invalidation_is_zero_sized(s, n.type, depth + 1)
	}
	return false
}

@(private = "file")
container_invalidation_is_byte :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> bool {
	e := e
	e = container_invalidation_resolve(s, e, 0)
	if e == nil {
		return false
	}
	name := container_invalidation_ident(e)
	return name == "u8" || name == "byte"
}

@(private)
container_invalidation_is_type :: proc(e: ^ast.Expr) -> bool {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return false
	}
	#partial switch _ in e.derived_expr {
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type,
	     ^ast.Pointer_Type, ^ast.Map_Type, ^ast.Proc_Type, ^ast.Helper_Type,
	     ^ast.Distinct_Type, ^ast.Bit_Set_Type, ^ast.Matrix_Type:
		return true
	}
	return false
}

@(private)
Container_Invalidation_Bool :: enum {
	Unknown,
	True,
	False,
}

@(private)
container_invalidation_bool :: proc(
	s: ^Container_Invalidation_State,
	e: ^ast.Expr,
) -> Container_Invalidation_Bool {
	e := e
	if id := container_invalidation_ident(container_invalidation_unparen(e)); id != "" &&
	   !container_invalidation_shadowed(s, id) {
		if id == "true" {
			return .True
		}
		if id == "false" {
			return .False
		}
	}
	return .Unknown
}

@(private)
container_invalidation_trips :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> (trips: int, known: bool) {
	bin, ok := container_invalidation_unparen(e).derived_expr.(^ast.Binary_Expr)
	if !ok {
		return
	}
	lo, lok := container_invalidation_int(s, bin.left)
	hi, hik := container_invalidation_int(s, bin.right)
	if !lok || !hik {
		return
	}
	#partial switch bin.op.kind {
	case .Range_Half:
		return max(0, hi - lo), true
	case .Range_Full:
		return max(0, hi - lo + 1), true
	case:
		return
	}
}

@(private)
container_invalidation_int :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> (n: int, ok: bool) {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return
	}
	#partial switch node in e.derived_expr {
	case ^ast.Basic_Lit:
		if node.tok.kind != .Integer {
			return
		}
		text, _ := strings.replace_all(node.tok.text, "_", "", context.temp_allocator)
		return strconv.parse_int(text)
	case ^ast.Ident:
		if container_invalidation_shadowed(s, node.name) {
			return
		}
		n, ok = s.consts[node.name]
	}
	return
}

@(private)
container_invalidation_arg :: proc(n: ^ast.Call_Expr, pos: int, name: string) -> ^ast.Expr {
	if pos < len(n.args) {
		if _, named := n.args[pos].derived_expr.(^ast.Field_Value); !named {
			return n.args[pos]
		}
	}
	for arg in n.args {
		field, ok := arg.derived_expr.(^ast.Field_Value)
		if !ok {
			continue
		}
		if container_invalidation_ident(field.field) == name {
			return field.value
		}
	}
	return nil
}

@(private)
container_invalidation_value_arg :: proc(e: ^ast.Expr) -> ^ast.Expr {
	if field, ok := e.derived_expr.(^ast.Field_Value); ok {
		return field.value
	}
	return e
}

// Only a plain identifier counts; unlike borrowed_escape_ident, unary
// wrappers are not aliases of a callable or local binding.
@(private)
container_invalidation_ident :: proc(e: ^ast.Expr) -> string {
	e := e
	e = container_invalidation_unparen(e)
	if e == nil {
		return ""
	}
	if id, ok := e.derived_expr.(^ast.Ident); ok {
		return id.name
	}
	return ""
}

@(private)
container_invalidation_unparen :: proc(e: ^ast.Expr) -> ^ast.Expr {
	e := e
	for e != nil {
		paren, ok := e.derived_expr.(^ast.Paren_Expr)
		if !ok {
			return e
		}
		e = paren.expr
	}
	return nil
}

@(private = "file")
container_invalidation_skip_field :: proc(e: ^ast.Expr) -> ^ast.Expr {
	e := e
	e = container_invalidation_unparen(e)
	for e != nil {
		sel, ok := e.derived_expr.(^ast.Selector_Expr)
		if !ok {
			return e
		}
		e = container_invalidation_unparen(sel.expr)
	}
	return nil
}

@(private)
container_invalidation_skip_deref :: proc(s: ^Container_Invalidation_State, e: ^ast.Expr) -> ^ast.Expr {
	e := e
	e = container_invalidation_unparen(e)
	deref, ok := e.derived_expr.(^ast.Deref_Expr)
	if !ok {
		return e
	}
	id := container_invalidation_ident(deref.expr)
	if _, is_alias := s.aliases[id]; is_alias {
		return deref.expr
	}
	if header, is_header := s.headers[id]; is_header && header.indirect {
		return deref.expr
	}
	return e
}

@(private)
container_invalidation_shadow_raw :: proc(s: ^Container_Invalidation_State, name: string) {
	if name == "" || !container_invalidation_is_builtin_name(name) {
		return
	}
	s.shadow[name] = s.shadow[name] + 1
}

@(private)
container_invalidation_shadowed :: proc(s: ^Container_Invalidation_State, name: string) -> bool {
	return s.shadow[name] > 0
}

@(private = "file")
container_invalidation_is_builtin_name :: proc(name: string) -> bool {
	for candidate in container_invalidation_growth_names {
		if candidate == name {
			return true
		}
	}
	for candidate in container_invalidation_len_names {
		if candidate == name {
			return true
		}
	}
	for candidate in container_invalidation_other_names {
		if candidate == name {
			return true
		}
	}
	return false
}

@(private)
container_invalidation_is_growth :: proc(name: string) -> bool {
	for candidate in container_invalidation_growth_names {
		if candidate == name {
			return true
		}
	}
	return false
}

@(private)
container_invalidation_is_len_op :: proc(name: string) -> bool {
	for candidate in container_invalidation_len_names {
		if candidate == name {
			return true
		}
	}
	return false
}
