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

File_Result :: struct {
	name:  string,
	decls: [dynamic]Decl,
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
	}
	return result
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
