// odin-review-extract prints the declarations of the Odin files it is given,
// as JSON, using Odin's own parser (core:odin). One line per invocation:
//
//	odin-review-extract file.odin ... > decls.json
//
// where the JSON is {"files":[{"name":"a.odin","decls":[
//	{"name":"main","kind":"func","line":7,"end_line":9,
//	 "exported":true,"test":false,"text":"...","doc":"..."}]}]}
//
// Odin has no export keyword: a package-level declaration is the package's
// API, so it is reported exported unless marked @(private=...).
//
// Beside the declarations, each file reports what a leak is read from: its
// struct types with their fields, and its release procedures — a procedure
// whose name carries destroy, free, deinit or delete as a word and whose
// first parameter is a type of this package, or a pointer to one — with
// every name the procedure hands to a call:
//
//	"structs":[{"name":"Index","line":3,"fields":[
//	 {"name":"names","type":"[dynamic]string","shape":"dynamic","line":4}]}],
//	"releases":[{"name":"index_destroy","line":8,"end_line":11,
//	 "target":"Index","names":["i","names"],"frees_all":false}]
package main

import "core:encoding/json"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"

Decl :: struct {
	name:     string,
	kind:     string,
	line:     int,
	end_line: int,
	exported: bool,
	test:     bool,
	text:     string,
	doc:      string,
}

// Field is one field of a struct type. shape is what its type is when
// that decides ownership: string, slice, map, dynamic or pointer for the
// types that own memory, named for a type named by a bare identifier,
// which the reader looks up in the package, other for the rest.
Field :: struct {
	name:  string,
	type:  string,
	shape: string,
	line:  int,
}

Struct :: struct {
	name:   string,
	line:   int,
	fields: [dynamic]Field,
}

// Release is a procedure that looks like it frees a value of target. names
// are the identifiers that appear anywhere in a call's arguments in its
// body; frees_all is a call to free_all or an arena's destroy, which
// releases everything the arena handed out at once.
Release :: struct {
	name:      string,
	line:      int,
	end_line:  int,
	target:    string,
	names:     [dynamic]string,
	frees_all: bool,
}

File_Result :: struct {
	name:     string,
	decls:    [dynamic]Decl,
	structs:  [dynamic]Struct,
	releases: [dynamic]Release,
}

Output :: struct {
	files: [dynamic]File_Result,
}

main :: proc() {
	args := os.args[1:]
	out := Output{}
	for arg in args {
		data, err := os.read_entire_file_from_path(arg, context.allocator)
		if err != nil {
			continue
		}
		append(&out.files, read_file(arg, data))
	}
	data, err := json.marshal(out, json.Marshal_Options{pretty = true, use_spaces = true})
	if err != nil {
		fmt.eprintf("odin-review-extract: %v\n", err)
		os.exit(1)
	}
	fmt.print(string(data))
}

read_file :: proc(path: string, src: []byte) -> File_Result {
	result := File_Result {
		name = path,
	}
	file := new(ast.File)
	file.fullpath = path
	file.src = string(src)

	p := parser.default_parser()
	parser.parse_file(&p, file)

	for stmt in file.decls {
		decl, ok := stmt.derived_stmt.(^ast.Value_Decl)
		if !ok {
			continue // Imports and foreign blocks are not this file's work.
		}
		private := is_private(decl.attributes[:])
		for name_expr in decl.names {
			ident, is_ident := name_expr.derived_expr.(^ast.Ident)
			if !is_ident {
				continue
			}
			entry := Decl {
				name     = ident.name,
				kind     = kind_of(decl),
				line     = int(name_expr.pos.line),
				end_line = int(stmt.end.line),
				exported = private == false,
				text     = line_text(src, name_expr.pos.line),
				doc      = doc_text(decl.docs),
			}
			if kind_of(decl) == "func" {
				entry.test = is_test(decl.attributes[:])
			}
			append(&result.decls, entry)
		}
		if len(decl.names) != 1 || len(decl.values) != 1 {
			continue
		}
		ident, is_ident := decl.names[0].derived_expr.(^ast.Ident)
		if !is_ident {
			continue
		}
		#partial switch v in decl.values[0].derived_expr {
		case ^ast.Struct_Type:
			append(&result.structs, struct_of(ident.name, int(ident.pos.line), v, src))
		case ^ast.Proc_Lit:
			if r, is_release := release_of(ident.name, v); is_release {
				r.line = int(ident.pos.line)
				r.end_line = int(stmt.end.line)
				append(&result.releases, r)
			}
		}
	}
	return result
}

// struct_of reads a struct type's fields, one entry per name.
struct_of :: proc(name: string, line: int, s: ^ast.Struct_Type, src: []byte) -> Struct {
	out := Struct {
		name = name,
		line = line,
	}
	if s.fields == nil {
		return out
	}
	for field in s.fields.list {
		if field.type == nil {
			continue
		}
		type := string(src[field.type.pos.offset:field.type.end.offset])
		for name_expr in field.names {
			if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
				append(
					&out.fields,
					Field {
						name = ident.name,
						type = type,
						shape = shape_of(field.type),
						line = int(name_expr.pos.line),
					},
				)
			}
		}
	}
	return out
}

// shape_of says whether a field's type owns memory, by its form alone.
// A fixed array, a multi-pointer and a type from another package are
// other: the first holds its elements inline, and for the rest the type
// alone does not say whether the struct owns what they point at.
shape_of :: proc(type: ^ast.Expr) -> string {
	#partial switch v in type.derived_expr {
	case ^ast.Ident:
		switch v.name {
		case "string", "cstring":
			return "string"
		}
		return "named"
	case ^ast.Array_Type:
		return "slice" if v.len == nil else "other"
	case ^ast.Dynamic_Array_Type:
		return "dynamic"
	case ^ast.Map_Type:
		return "map"
	case ^ast.Pointer_Type:
		return "pointer"
	case ^ast.Poly_Type:
		// A polymorphic struct's own parameter, $T or T/[]E: not known.
		return "other"
	}
	return "other"
}

// release_verbs are the words a procedure's name carries when it frees a
// value.
release_verbs := []string{"destroy", "free", "deinit", "delete"}

// release_of reads a procedure that may release a value of this package's
// types: its name has a release verb as one of its words, and its first
// parameter is a named type or a pointer to one.
release_of :: proc(name: string, p: ^ast.Proc_Lit) -> (r: Release, ok: bool) {
	verb := false
	for word in strings.split(name, "_", context.temp_allocator) {
		for v in release_verbs {
			verb ||= word == v
		}
	}
	if !verb || p.body == nil || p.type == nil || p.type.params == nil ||
	   len(p.type.params.list) == 0 {
		return
	}
	type := p.type.params.list[0].type
	if type == nil {
		return
	}
	if ptr, is_ptr := type.derived_expr.(^ast.Pointer_Type); is_ptr {
		type = ptr.elem
	}
	target, named := type.derived_expr.(^ast.Ident)
	if !named {
		return
	}
	r = Release {
		name   = name,
		target = target.name,
	}
	v := ast.Visitor {
		visit = visit_release,
		data  = &r,
	}
	ast.walk(&v, p.body)
	return r, true
}

// visit_release reads one node of a release procedure's body: a call's
// callee for free_all and arena destroys, and every identifier in its
// arguments. A call nested in another's arguments is visited again on its
// own; the names it adds are already there.
visit_release :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	call, is_call := node.derived.(^ast.Call_Expr)
	if !is_call {
		return v
	}
	r := (^Release)(v.data)
	callee := ""
	#partial switch c in call.expr.derived_expr {
	case ^ast.Ident:
		callee = c.name
	case ^ast.Selector_Expr:
		callee = c.field.name
	}
	if callee == "free_all" || strings.has_suffix(callee, "arena_destroy") {
		r.frees_all = true
	}
	names := ast.Visitor {
		visit = visit_names,
		data  = &r.names,
	}
	for arg in call.args {
		ast.walk(&names, arg)
	}
	return v
}

// visit_names collects every identifier under a node, once each.
visit_names :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	if ident, ok := node.derived.(^ast.Ident); ok {
		names := (^[dynamic]string)(v.data)
		for n in names {
			if n == ident.name {
				return v
			}
		}
		append(names, ident.name)
	}
	return v
}

// kind_of reports what a value declaration declares: a procedure, a type, or
// a value. The type sits on the declaration, or in its only value when the
// declaration is `name :: thing`.
kind_of :: proc(decl: ^ast.Value_Decl) -> string {
	kind := "value"
	if decl.type != nil {
		kind = expr_kind(decl.type.derived_expr)
	}
	for value in decl.values {
		if k := expr_kind(value.derived_expr); k != "value" {
			return k
		}
	}
	return kind
}

expr_kind :: proc(e: ast.Any_Expr) -> string {
	#partial switch v in e {
	case ^ast.Proc_Lit:
		return "func"
	case ^ast.Proc_Group:
		return "func"
	case ^ast.Struct_Type,
	     ^ast.Union_Type,
	     ^ast.Enum_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Distinct_Type,
	     ^ast.Poly_Type,
	     ^ast.Typeid_Type,
	     ^ast.Pointer_Type,
	     ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Fixed_Capacity_Dynamic_Array_Type,
	     ^ast.Map_Type,
	     ^ast.Relative_Type,
	     ^ast.Matrix_Type,
	     ^ast.Bit_Field_Type:
		return "type"
	case:
		return "value"
	}
	return "value"
}

// is_test reports the @(test) attribute, which the testing package runs.
is_test :: proc(attributes: []^ast.Attribute) -> bool {
	for attribute in attributes {
		for elem in attribute.elems {
			#partial switch v in elem.derived_expr {
			case ^ast.Ident:
				if v.name == "test" {
					return true
				}
			case ^ast.Field_Value:
				if field, ok := v.field.derived_expr.(^ast.Ident); ok && field.name == "test" {
					return true
				}
			}
		}
	}
	return false
}

// is_private reports an @(private=...) attribute, which keeps a declaration
// out of the package's public surface.
is_private :: proc(attributes: []^ast.Attribute) -> bool {
	for attribute in attributes {
		for elem in attribute.elems {
			if field, is_field := elem.derived_expr.(^ast.Field_Value); is_field {
				if name, named := field.field.derived_expr.(^ast.Ident);
				   named && name.name == "private" {
					return true
				}
			}
		}
	}
	return false
}

doc_text :: proc(group: ^ast.Comment_Group) -> string {
	if group == nil {
		return ""
	}
	parts: [dynamic]string
	for token in group.list {
		t := strings.trim_space(token.text)
		switch {
		case strings.has_prefix(t, "///"):
			t = strings.trim_prefix(t, "///")
		case strings.has_prefix(t, "//"):
			t = strings.trim_prefix(t, "//")
		case strings.has_prefix(t, "/*"):
			t = strings.trim_suffix(strings.trim_prefix(t, "/*"), "*/")
			for raw in strings.split(t, "\n") {
				line := strings.trim_space(raw)
				line = strings.trim_prefix(line, "*")
				line = strings.trim_space(line)
				if len(line) > 0 {
					append(&parts, line)
				}
			}
			continue
		}
		t = strings.trim_space(t)
		if len(t) > 0 {
			append(&parts, t)
		}
	}
	defer delete(parts)
	return strings.join(parts[:], " ")
}

line_text :: proc(src: []byte, line: int) -> string {
	current := 1
	start := 0
	for i := 0; i < len(src); i += 1 {
		if src[i] == '\n' {
			if current == line {
				return strings.trim_space(string(src[start:i]))
			}
			current += 1
			start = i + 1
		}
	}
	if current == line {
		return strings.trim_space(string(src[start:]))
	}
	return ""
}
