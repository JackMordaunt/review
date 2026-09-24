package frontend

// TypeScript, JavaScript, Python and Rust are read through ast-grep, which
// matches patterns and node kinds against the tree-sitter syntax tree
// rather than against lines. A pattern over lines misses an indented
// constant inside a block; a query over syntax does not. The answer is
// shaped like a sidecar's, so the change reads every language one way.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "jm:sh"

// Pattern is one top-level declaration shape a TypeScript grammar binds.
// Export status is part of the pattern so a symbol's audience is known;
// the plain forms also match the inner node of an export, which the
// reader resolves by preferring the exported match.
Pattern :: struct {
	kind:     string,
	exported: bool,
	pattern:  string,
}

@(private = "file")
ts_patterns := []Pattern {
	{"value", false, "const $N = $$$V"},
	{"value", true, "export const $N = $$$V"},
	{"value", false, "const $N: $$$T = $$$V"},
	{"value", true, "export const $N: $$$T = $$$V"},
	{"value", false, "let $N = $$$V"},
	{"value", true, "export let $N = $$$V"},
	{"value", true, "export let $N: $$$T = $$$V"},
	{"value", false, "var $N = $$$V"},
	{"value", true, "export var $N = $$$V"},
	{"type", false, "type $N = $$$B"},
	{"type", true, "export type $N = $$$B"},
	{"type", false, "interface $N { $$$B }"},
	{"type", true, "export interface $N { $$$B }"},
	{"type", false, "enum $N { $$$V }"},
	{"type", true, "export enum $N { $$$V }"},
	{"type", false, "class $N { $$$B }"},
	{"type", true, "export class $N { $$$B }"},
	{"func", false, "function $N($$$P) { $$$B }"},
	{"func", true, "export function $N($$$P) { $$$B }"},
	{"func", true, "export function $N($$$P): $$$R { $$$B }"},
	{"func", false, "async function $N($$$P) { $$$B }"},
	{"func", true, "export async function $N($$$P) { $$$B }"},
	{"func", true, "export async function $N($$$P): $$$R { $$$B }"},
	{"func", true, "export default function $N($$$P) { $$$B }"},
	{"func", true, "export default function $N($$$P): $$$R { $$$B }"},
}

// ts_test_patterns bind the runner's calls, in the shapes Node's
// node:test, Bun's bun:test, Deno's Deno.test and the Jest family write
// them. A test inside a describe block is still a test, so these carry no
// top-level constraint. The name is $S when the test is named by a string
// and $N when by a function.
@(private = "file")
ts_test_patterns := []string {
	"test($S, $$$B)",
	"it($S, $$$B)",
	"test.$M($S, $$$B)",
	"it.$M($S, $$$B)",
	"test.$M($$$T)($S, $$$B)",
	"it.$M($$$T)($S, $$$B)",
	"Deno.test($S, $$$B)",
	"Deno.test.$M($S, $$$B)",
	"Deno.test({ name: $S, $$$R })",
	"Deno.test(function $N($$$P) { $$$B })",
}

// Kind_Rule is one declaration shape read by node kind: the ast-grep rule
// that matches it, the kind the tool reports it as, and the expression
// that reads its name out of the match text.
Kind_Rule :: struct {
	id:   string,
	kind: string,
	rule: string,
	name: string,
	test: bool,
}

@(private = "file")
py_top :: "  not:\n    inside:\n      any:\n        - kind: function_definition\n        - kind: class_definition\n      stopBy: end\n"

// Python: module-level functions, classes and assignments, and any
// function named test_. A leading underscore is the language's whole
// notion of private.
@(private = "file")
py_rules := []Kind_Rule {
	{
		"py-func",
		"func",
		"  kind: function_definition\n" + py_top,
		`^\s*(?:async\s+)?def\s+(\w+)`,
		false,
	},
	{"py-class", "type", "  kind: class_definition\n" + py_top, `^\s*class\s+(\w+)`, false},
	{
		"py-value",
		"value",
		"  kind: assignment\n  inside:\n    kind: expression_statement\n    inside:\n      kind: module\n",
		`^\s*(\w+)\s*(?::[^=]*)?=`,
		false,
	},
	{
		"py-test",
		"func",
		"  kind: function_definition\n  has:\n    field: name\n    regex: ^test_\n",
		`^\s*(?:async\s+)?def\s+(\w+)`,
		true,
	},
}

// Rust: functions wherever they are declared, impl methods included, the
// type items, constants and statics, and any function a test attribute
// precedes. pub is the whole notion of exported.
@(private = "file")
rs_rules := []Kind_Rule {
	{"rs-func", "func", "  kind: function_item\n", `\bfn\s+(\w+)`, false},
	{
		"rs-type",
		"type",
		"  any:\n    - kind: struct_item\n    - kind: enum_item\n    - kind: type_item\n    - kind: trait_item\n",
		`\b(?:struct|enum|type|trait)\s+(\w+)`,
		false,
	},
	{
		"rs-value",
		"value",
		"  any:\n    - kind: const_item\n    - kind: static_item\n",
		`\b(?:const|static)\s+(?:mut\s+)?(\w+)`,
		false,
	},
	{
		"rs-test",
		"func",
		"  kind: function_item\n  follows:\n    kind: attribute_item\n    regex: '^#\\[[\\w:]*test(\\(|\\])'\n",
		`\bfn\s+(\w+)`,
		true,
	},
}

// grammar_of is the ast-grep grammar a path is parsed with, or empty
// where none of the pattern grammars reads it.
grammar_of :: proc(path: string) -> string {
	switch {
	case strings.has_suffix(path, ".ts"):
		return "ts"
	case strings.has_suffix(path, ".tsx"):
		return "tsx"
	case strings.has_suffix(path, ".js") ||
	     strings.has_suffix(path, ".jsx") ||
	     strings.has_suffix(path, ".mjs") ||
	     strings.has_suffix(path, ".cjs"):
		return "js"
	}
	return ""
}

// scratch_ext is the extension a file is materialised under, which is
// what ast-grep infers the grammar from. The module variants of
// JavaScript are the same grammar under another name.
scratch_ext :: proc(path: string) -> string {
	ext := filepath.ext(path)
	if ext == ".mjs" || ext == ".cjs" {
		return ".js"
	}
	return ext
}

// typed is whether a pattern needs TypeScript's grammar: an annotation,
// an interface, a type alias or an enum is not JavaScript.
typed :: proc(pattern: string) -> bool {
	bare := strings.trim_prefix(pattern, "export ")
	return(
		strings.contains(pattern, ": $$$") ||
		strings.has_prefix(bare, "type ") ||
		strings.contains(pattern, "interface ") ||
		strings.contains(pattern, "enum ") \
	)
}

// write_rules emits the query set for a language into the rules
// directory. The top-level rule keeps TypeScript declarations out of
// function bodies; the test rules go anywhere.
write_rules :: proc(sidecar: Sidecar, dir: string) -> bool {
	switch sidecar {
	case .Script:
		Table :: struct {
			prefix, language: string,
		}
		for table in ([]Table{{"ts", "TypeScript"}, {"tsx", "TSX"}, {"js", "JavaScript"}}) {
			for p, i in ts_patterns {
				if table.prefix == "js" && typed(p.pattern) {
					continue
				}
				status := "export" if p.exported else "plain"
				id := fmt.tprintf("%s-%s-%s-%d", table.prefix, p.kind, status, i)
				body := fmt.tprintf(
					"id: %s\nlanguage: %s\nseverity: info\nrule:\n  pattern: %q\n  not:\n    inside:\n      kind: statement_block\n      stopBy: end\n",
					id,
					table.language,
					p.pattern,
				)
				write_rule(dir, id, body) or_return
			}
			for pattern, i in ts_test_patterns {
				id := fmt.tprintf("%s-test-%d", table.prefix, i)
				write_rule(
					dir,
					id,
					fmt.tprintf(
						"id: %s\nlanguage: %s\nseverity: info\nrule:\n  pattern: %q\n",
						id,
						table.language,
						pattern,
					),
				) or_return
			}
		}
	case .Python, .Rust:
		language := "Python" if sidecar == .Python else "Rust"
		for r in (py_rules if sidecar == .Python else rs_rules) {
			write_rule(
				dir,
				r.id,
				fmt.tprintf(
					"id: %s\nlanguage: %s\nseverity: info\nrule:\n%s",
					r.id,
					language,
					r.rule,
				),
			) or_return
		}
	case .Go, .Odin:
		return false
	}
	return true
}

write_rule :: proc(dir, id, body: string) -> bool {
	path :=
		filepath.join(
			{dir, strings.concatenate({id, ".yml"}, context.temp_allocator)},
			context.temp_allocator,
		) or_else id
	return os.write_entire_file(path, transmute([]byte)body) == nil
}

// Grep_Match is one ast-grep finding, as its --json prints it.
Grep_Match :: struct {
	rule:  string `json:"ruleId"`,
	text:  string `json:"text"`,
	file:  string `json:"file"`,
	range: struct {
		start: struct {
			line: int `json:"line"`,
		} `json:"start"`,
	} `json:"range"`,
	meta:  struct {
		single: map[string]struct {
			text: string `json:"text"`,
		} `json:"single"`,
	} `json:"metaVariables"`,
}

// grep_scan materialises the files into a scratch directory under
// numbered names, writes the rules, asks ast-grep for the matches, and
// reads them back into the sidecar shape, one File per path given.
grep_scan :: proc(
	sidecar: Sidecar,
	files: []string,
	allocator := context.allocator,
) -> (
	out: Output,
	err: Scan_Error,
) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	dir, made := os.make_directory_temp(temp, "review-grep-*", context.temp_allocator)
	if made != nil {
		return out, .Failed
	}
	defer os.remove_all(dir)
	rules := filepath.join({dir, "rules"}, context.temp_allocator) or_else ""
	if os.make_directory_all(rules) != nil {
		return out, .Failed
	}
	config := filepath.join({dir, "sgconfig.yml"}, context.temp_allocator) or_else ""
	if os.write_entire_file(config, transmute([]byte)string("ruleDirs:\n  - rules\n")) != nil {
		return out, .Failed
	}
	if !write_rules(sidecar, rules) {
		return out, .Failed
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "ast-grep", "scan", "-c", config, "--json")
	sources := make([][]byte, len(files), context.temp_allocator)
	for name, i in files {
		source, read_err := os.read_entire_file_from_path(name, allocator)
		if read_err != nil {
			continue
		}
		sources[i] = source
		scratch :=
			filepath.join(
				{dir, fmt.tprintf("%04d%s", i, scratch_ext(name))},
				context.temp_allocator,
			) or_else ""
		if os.write_entire_file(scratch, source) != nil {
			return out, .Failed
		}
		append(&argv, scratch)
	}
	r := sh.exec(argv[:], allocator = context.temp_allocator)
	if !r.ok && len(r.stdout) == 0 {
		return out, .Failed
	}
	matches: []Grep_Match
	if json.unmarshal_string(r.stdout, &matches, allocator = context.temp_allocator) != nil {
		return out, .Unreadable
	}
	out.files = make([]File, len(files), allocator)
	for name, i in files {
		out.files[i] = File {
			name     = strings.clone(name, allocator),
			imports  = {},
			decls    = {},
			comments = {},
		}
	}
	// One declaration, several matches: the plain forms see the inner
	// node of an export, and a test function is also a function. Keep the
	// exported reading, and the test reading, of each line.
	best := make(map[string]Grep_Match, context.temp_allocator)
	for m in matches {
		base := strings.trim_suffix(filepath.base(m.file), filepath.ext(m.file))
		index, numbered := strconv.parse_int(base)
		if !numbered || index < 0 || index >= len(files) {
			continue
		}
		key := fmt.tprintf("%d:%d", index, m.range.start.line)
		if old, seen := best[key]; seen && !prefer(m.rule, old.rule) {
			continue
		}
		best[strings.clone(key, context.temp_allocator)] = m
	}
	decls := make([][dynamic]Decl, len(files), context.temp_allocator)
	for i in 0 ..< len(files) {
		decls[i] = make([dynamic]Decl, allocator)
	}
	for key, m in best {
		index, _ := strconv.parse_int(key[:strings.index_byte(key, ':')])
		lines := strings.split_lines(string(sources[index]), context.temp_allocator)
		if decl, ok := read_match(sidecar, m, lines, allocator); ok {
			append(&decls[index], decl)
		}
	}
	for i in 0 ..< len(files) {
		slice.sort_by_cmp(decls[i][:], proc(a, b: Decl) -> slice.Ordering {
			return .Less if a.line < b.line else (.Greater if a.line > b.line else .Equal)
		})
		out.files[i].decls = decls[i][:]
	}
	return out, .None
}

// prefer is whether a new match outranks the one already kept for a
// line: an export over a plain form, a test over the function it also is.
prefer :: proc(rule, old: string) -> bool {
	if strings.contains(rule, "export") && !strings.contains(old, "export") {
		return true
	}
	return strings.contains(rule, "test") && !strings.contains(old, "test")
}

// read_match reads one declaration out of a match: its name from the
// bound metavariable or the match text, its kind from the rule, and its
// audience from the language's notion of it.
read_match :: proc(
	sidecar: Sidecar,
	m: Grep_Match,
	lines: []string,
	allocator := context.allocator,
) -> (
	decl: Decl,
	ok: bool,
) {
	line := m.range.start.line + 1
	decl.line = line
	decl.end_line = line + strings.count(m.text, "\n")
	decl.test = strings.contains(m.rule, "test")
	switch sidecar {
	case .Script:
		name := ""
		for key in ([]string{"N", "S"}) {
			if bound, found := m.meta.single[key]; found {
				name = bound.text
				break
			}
		}
		if decl.test {
			name = strings.trim(name, "\"'`")
		}
		if name == "" {
			return decl, false
		}
		decl.name = strings.clone(name, allocator)
		decl.kind = rule_kind(m.rule)
		decl.exported = strings.contains(m.rule, "export")
	case .Python, .Rust:
		rule, known := kind_rule(sidecar, m.rule)
		if !known {
			return decl, false
		}
		re, err := regex.create(rule.name, {}, context.temp_allocator, context.temp_allocator)
		if err != nil {
			return decl, false
		}
		cap, matched := regex.match(re, m.text, context.temp_allocator)
		if !matched || len(cap.groups) < 2 {
			return decl, false
		}
		decl.name = strings.clone(cap.groups[1], allocator)
		decl.kind = rule.kind
		decl.exported =
			!strings.has_prefix(decl.name, "_") if sidecar == .Python else strings.has_prefix(strings.trim_space(m.text), "pub")
	case .Go, .Odin:
		return decl, false
	}
	if line - 1 < len(lines) {
		decl.text = strings.clone(strings.trim_space(lines[line - 1]), allocator)
	}
	decl.doc = doc_above(lines, line, allocator)
	decl.body = strings.clone(m.text, allocator)
	return decl, true
}

kind_rule :: proc(sidecar: Sidecar, id: string) -> (Kind_Rule, bool) {
	for r in (py_rules if sidecar == .Python else rs_rules) {
		if r.id == id {
			return r, true
		}
	}
	return {}, false
}

// rule_kind turns a rule id back into the shape the findings report.
rule_kind :: proc(rule: string) -> string {
	switch {
	case strings.contains(rule, "-func-"), strings.contains(rule, "-test-"):
		return "func"
	case strings.contains(rule, "-type-"):
		return "type"
	}
	return "value"
}

// doc_above collects the comment block ending on the line before the
// declaration, as the doc a reader would attach to it, in the C-family
// shapes and Python's.
doc_above :: proc(lines: []string, line: int, allocator := context.allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for i := line - 2; i >= 0; i -= 1 {
		trimmed := strings.trim_space(lines[i])
		if !strings.has_prefix(trimmed, "//") &&
		   !strings.has_prefix(trimmed, "*") &&
		   !strings.has_prefix(trimmed, "/*") &&
		   (!strings.has_prefix(trimmed, "#") || strings.has_prefix(trimmed, "#!")) {
			break
		}
		trimmed = strings.trim_prefix(trimmed, "#")
		trimmed = strings.trim_prefix(trimmed, "///")
		trimmed = strings.trim_prefix(trimmed, "//")
		trimmed = strings.trim_prefix(trimmed, "/**")
		trimmed = strings.trim_prefix(trimmed, "/*")
		trimmed = strings.trim_suffix(trimmed, "*/")
		part := strings.trim_space(strings.trim_prefix(trimmed, "*"))
		if part != "" {
			inject_at(&parts, 0, part)
		}
	}
	return strings.join(parts[:], " ", allocator)
}
