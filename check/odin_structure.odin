package check

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "../finding"

// Odin_Structure_File retains parsed syntax while the repository-wide
// package check counts directories rather than files.
@(private = "file")
Odin_Structure_File :: struct {
	path, dir: string,
	file:      ^ast.File,
}

// check_odin_structure confines entry points to cmd and the standard CLI
// parser to one cli package. Unchanged files provide repository context;
// only a changed package declaration or parser call receives a finding.
check_odin_structure :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	files := make([dynamic]Odin_Structure_File, context.temp_allocator)
	cli_dirs := make(map[string]bool, context.temp_allocator)
	for path in sorted_keys(s.sources) {
		if !strings.has_suffix(path, ".odin") || is_test_file(path) {
			continue
		}
		file := parse_odin_source(path, string(s.sources[path]))
		if file == nil || file.pkg_decl == nil {
			continue
		}
		dir := "."
		if slash := strings.last_index_byte(path, '/'); slash >= 0 {
			dir = path[:slash]
		}
		append(&files, Odin_Structure_File{path, dir, file})
		if file.pkg_decl.name == "cli" {
			cli_dirs[dir] = true
		}
	}
	w := Odin_CLI_Walk {
		aliases = make(map[string]bool, context.temp_allocator),
	}
	for f in files {
		clear(&w.aliases)
		clear(&w.calls)
		pkg := f.file.pkg_decl
		if line_was_added(s, f.path, pkg.pos.line) {
			if pkg.name == "main" && !strings.has_prefix(f.path, "cmd/") {
				append(
					out,
					static(
						"odin-main-location",
						.Must_Fix,
						"Odin package main is outside the repository's cmd subtree",
						"move the executable package under cmd/ (for example cmd/cli or cmd/gui)",
						file = f.path,
						line = pkg.pos.line,
					),
				)
			}
			if pkg.name == "cli" && len(cli_dirs) > 1 {
				append(
					out,
					static(
						"odin-cli-package",
						.Must_Fix,
						fmt.aprintf(
							"%d directories declare package cli; CLI parsing needs one package",
							len(cli_dirs),
						),
						"consolidate command-line parsing in a single cli package",
						file = f.path,
						line = pkg.pos.line,
					),
				)
			}
		}
		if pkg.name == "cli" {
			continue
		}
		for imp in f.file.imports {
			if strings.trim(imp.relpath.text, "\"`") != "core:flags" {
				continue
			}
			alias := imp.name.text
			if alias == "" {
				alias = "flags"
			}
			if alias != "_" {
				w.aliases[alias] = true
			}
		}
		if len(w.aliases) == 0 {
			continue
		}
		v := ast.Visitor {
			visit = odin_cli_visit,
			data  = &w,
		}
		for decl in f.file.decls {
			ast.walk(&v, decl)
		}
		for call in w.calls {
			if w.aliases[call.alias] && line_was_added(s, f.path, call.line) {
				append(
					out,
					static(
						"odin-cli-parsing",
						.Must_Fix,
						"a package other than cli calls core:flags.parse",
						"parse command-line arguments in the cli package and pass typed values to domain packages",
						file = f.path,
						line = call.line,
					),
				)
			}
		}
	}
}

@(private = "file")
line_was_added :: proc(s: Scope, path: string, line: int) -> bool {
	lines, ok := s.c.added[path]
	if !ok {
		return false
	}
	for l in lines {
		if l.line == line {
			return true
		}
	}
	return false
}

@(private = "file")
Odin_CLI_Call :: struct {
	alias: string,
	line:  int,
}

@(private = "file")
Odin_CLI_Walk :: struct {
	aliases: map[string]bool,
	calls:   [dynamic]Odin_CLI_Call,
}

// A local declaration with an import's name makes name resolution
// uncertain. Suppress that alias conservatively instead of attributing a
// method on a local value to the imported package.
@(private = "file")
odin_cli_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return v
	}
	w := (^Odin_CLI_Walk)(v.data)
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		for expr in n.names {
			if ident, ok := expr.derived_expr.(^ast.Ident); ok {
				delete_key(&w.aliases, ident.name)
			}
		}
	case ^ast.Field:
		for expr in n.names {
			if ident, ok := expr.derived_expr.(^ast.Ident); ok {
				delete_key(&w.aliases, ident.name)
			}
		}
	case ^ast.Call_Expr:
		if sel, ok := n.expr.derived_expr.(^ast.Selector_Expr);
		   ok && sel.field != nil && sel.field.name == "parse" {
			if ident, is_ident := sel.expr.derived_expr.(^ast.Ident); is_ident {
				append(&w.calls, Odin_CLI_Call{ident.name, n.pos.line})
			}
		}
	}
	return v
}
