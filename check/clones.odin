package check

// Two functions with the same body are one fact stated twice, and telling
// that two bodies are the same needs no judgement: the tokens either
// match or they do not. Whether two different bodies mean the same thing
// is the duplication job's.

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../change"
import "../finding"

// The floors under which two bodies are not compared. Two one-line
// accessors are alike because accessors are alike; a match in shape alone
// needs a body twice as long, because two small wrappers share a shape
// because wrappers do.
min_clone_tokens :: 40
min_shape_tokens :: 80

@(private = "file")
keywords: map[string]map[string]bool

@(init)
init_keywords :: proc "contextless" () {
	context = runtime.default_context()
	// The words a language reserves, per grammar, which a structural
	// comparison keeps while it replaces every other identifier.
	keywords = make(map[string]map[string]bool, runtime.heap_allocator())
	keywords["go"] = set(
		`break case chan const continue default defer else fallthrough for func go goto if import
		interface map package range return select struct switch type var nil true false iota
		len cap append make new panic recover error string int int8 int16 int32 int64 uint uint8 uint16
		uint32 uint64 byte rune float32 float64 bool any`,
	)
	keywords["js"] = set(
		`break case catch class const continue debugger default delete do else enum export extends
		false finally for function if import in instanceof new null return super switch this throw true
		try typeof var void while with yield let static async await of undefined interface type
		implements private public protected readonly declare namespace abstract as is keyof never
		unknown string number boolean object symbol bigint`,
	)
	keywords["py"] = set(
		`False None True and as assert async await break class continue def del elif else except
		finally for from global if import in is lambda nonlocal not or pass raise return try while with
		yield self cls print len range str int float list dict set tuple bool`,
	)
	keywords["rs"] = set(
		`as async await break const continue crate dyn else enum extern false fn for if impl in let
		loop match mod move mut pub ref return self Self static struct super trait true type unsafe use
		where while Some None Ok Err Vec String Option Result Box i8 i16 i32 i64 u8 u16 u32 u64 usize
		isize f32 f64 bool char str`,
	)
	keywords["odin"] = set(
		`package import foreign proc struct union enum bit_set map dynamic using if else when for
		switch case in not_in defer return break continue fallthrough cast transmute auto_cast distinct
		matrix or_else or_return or_break or_continue where do context true false nil int uint bool
		string rune byte f32 f64 i8 i16 i32 i64 u8 u16 u32 u64 uintptr rawptr any typeid`,
	)
	keywords["sh"] = set(
		`if then elif else fi for while until do done case esac in function select time coproc
		local readonly declare typeset export unset return break continue shift trap eval exec source
		set echo printf test true false cd read exit command builtin wait kill jobs umask getopts`,
	)
}

// keywords_for is which keyword set a file's tokens are read with — not
// the same question as grammar_of, which answers with an ast-grep
// grammar. A shell script is told apart by its dialect rather than its
// name: most carry no extension.
keywords_for :: proc(path, shell: string) -> string {
	switch {
	case strings.has_suffix(path, ".go"):
		return "go"
	case strings.has_suffix(path, ".odin"):
		return "odin"
	case strings.has_suffix(path, ".py"):
		return "py"
	case strings.has_suffix(path, ".rs"):
		return "rs"
	case grammar_of(path) != "":
		return "js"
	case shell != "":
		return "sh"
	}
	if dot := strings.last_index_byte(path, '.'); dot >= 0 {
		return path[dot:]
	}
	return ""
}

// Shapes are a body's two normalisations: exact, with only the function's
// own name replaced, and structural, with every identifier and literal
// replaced. Empty when the body is too small to compare.
Shapes :: struct {
	exact:      string,
	structural: string,
	tokens:     int,
}

// normalise reads a body into its shapes. Whitespace and comments are
// gone in both; the exact shape keeps every name but the function's own,
// the structural shape keeps only the grammar's keywords and punctuation.
normalise :: proc(body, name, grammar: string, allocator := context.allocator) -> Shapes {
	toks := lexemes(strip_comments(body, context.temp_allocator), context.temp_allocator)
	if len(toks) < min_clone_tokens {
		return Shapes{}
	}
	reserved := keywords[grammar]
	exact := make([]string, len(toks), context.temp_allocator)
	structural := make([]string, len(toks), context.temp_allocator)
	for t, i in toks {
		exact[i] = "NAME" if t == name else t
		c := t[0]
		switch {
		case reserved[t]:
			structural[i] = t
		case c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			structural[i] = "ID"
		case c == '"' || c == '\'' || c == '`' || (c >= '0' && c <= '9'):
			structural[i] = "LIT"
		case:
			structural[i] = t
		}
	}
	return Shapes {
		exact = strings.join(exact, " ", allocator),
		structural = strings.join(structural, " ", allocator),
		tokens = len(toks),
	}
}

// strip_comments blanks what a tokeniser drops: line comments, block
// comments, and the hash comments of the languages that write them at a
// line's start.
strip_comments :: proc(body: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	line_start := true
	for i < len(body) {
		c := body[i]
		switch {
		case c == '/' && i + 1 < len(body) && body[i + 1] == '/':
			for i < len(body) && body[i] != '\n' {
				i += 1
			}
			strings.write_byte(&b, ' ')
			continue
		case c == '/' && i + 1 < len(body) && body[i + 1] == '*':
			end := strings.index(body[i + 2:], "*/")
			i = len(body) if end < 0 else i + 2 + end + 2
			strings.write_byte(&b, ' ')
			continue
		case c == '#' && line_start:
			for i < len(body) && body[i] != '\n' {
				i += 1
			}
			strings.write_byte(&b, ' ')
			continue
		case c == '"' || c == '\'' || c == '`':
			// A string is copied whole, so a comment marker inside it is
			// not a comment.
			j := i + 1
			for j < len(body) && body[j] != c {
				if body[j] == '\\' && c != '`' {
					j += 1
				}
				if body[j] == '\n' && c != '`' {
					break
				}
				j += 1
			}
			j = min(j + 1, len(body))
			strings.write_string(&b, body[i:j])
			i = j
			line_start = false
			continue
		}
		strings.write_byte(&b, c)
		if c == '\n' {
			line_start = true
		} else if c != ' ' && c != '\t' {
			line_start = false
		}
		i += 1
	}
	return strings.to_string(b)
}

// lexemes reads the lexical tokens of the C-family languages: an
// identifier, a number, a string in any of three quotings, a
// two-character operator, or one character of punctuation.
lexemes :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i += 1
		case c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			j := i + 1
			for j < len(text) &&
			    (text[j] == '_' ||
					    (text[j] >= 'a' && text[j] <= 'z') ||
					    (text[j] >= 'A' && text[j] <= 'Z') ||
					    (text[j] >= '0' && text[j] <= '9')) {
				j += 1
			}
			append(&out, text[i:j])
			i = j
		case c >= '0' && c <= '9':
			j := i + 1
			if c == '0' && j < len(text) && (text[j] == 'x' || text[j] == 'X') {
				j += 1
				for j < len(text) && is_hex(text[j]) {
					j += 1
				}
			} else {
				for j < len(text) && text[j] >= '0' && text[j] <= '9' {
					j += 1
				}
				if j + 1 < len(text) &&
				   text[j] == '.' &&
				   text[j + 1] >= '0' &&
				   text[j + 1] <= '9' {
					j += 1
					for j < len(text) && text[j] >= '0' && text[j] <= '9' {
						j += 1
					}
				}
			}
			append(&out, text[i:j])
			i = j
		case c == '"' || c == '\'' || c == '`':
			j := i + 1
			for j < len(text) && text[j] != c {
				if c != '`' && text[j] == '\\' {
					j += 1
				} else if c != '`' && text[j] == '\n' {
					break
				}
				j += 1
			}
			if j < len(text) && text[j] == c {
				append(&out, text[i:j + 1])
				i = j + 1
			} else {
				append(&out, text[i:i + 1])
				i += 1
			}
		case:
			if i + 1 < len(text) && is_double_operator(text[i:i + 2]) {
				append(&out, text[i:i + 2])
				i += 2
			} else {
				append(&out, text[i:i + 1])
				i += 1
			}
		}
	}
	return out[:]
}

is_hex :: proc(c: byte) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

is_double_operator :: proc(s: string) -> bool {
	switch s {
	case ":=",
	     "::",
	     "==",
	     "!=",
	     "<=",
	     ">=",
	     "&&",
	     "||",
	     "++",
	     "--",
	     "+=",
	     "-=",
	     "*=",
	     "/=",
	     "->",
	     "=>",
	     "<<",
	     ">>":
		return true
	}
	return false
}

// Owned is one function with its shapes, and where it is declared.
Owned :: struct {
	name:  string,
	file:  string,
	line:  int,
	shape: Shapes,
}

// check_clones reports a new function whose body already exists: in the
// repository's index, or in another function the same change adds. An
// exact match is one function written twice and is must-fix; a match in
// shape alone, every name changed, is the same procedure over other
// names, and is worth considering.
check_clones :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	fresh := make([dynamic]Owned, context.temp_allocator)
	for sym in s.c.symbols {
		if sym.kind != "func" || sym.body == "" || is_test_file(sym.file) {
			continue
		}
		shape := normalise(
			sym.body,
			sym.name,
			keywords_for(sym.file, change.shell_for(s.c, sym.file)),
			context.temp_allocator,
		)
		if shape.tokens == 0 {
			continue
		}
		append(&fresh, Owned{sym.name, sym.file, sym.line, shape})
	}
	if len(fresh) == 0 {
		return
	}
	existing := make([dynamic]Owned, context.temp_allocator)
	for d in s.c.index {
		if d.kind != "func" || d.body == "" {
			continue
		}
		shape := normalise(
			d.body,
			d.name,
			keywords_for(d.file, d.shell),
			context.temp_allocator,
		)
		if shape.tokens == 0 {
			continue
		}
		append(&existing, Owned{d.name, d.file, d.line, shape})
	}
	reported := make(map[string]bool, context.temp_allocator)
	for a in fresh {
		for b in existing {
			if a.file == b.file && a.line == b.line {
				continue
			}
			alike(a, b, &reported, out)
		}
	}
	// Two new functions alike are reported once, the later against the
	// earlier, where the index did not already hold the earlier.
	for a, i in fresh {
		for b in fresh[:i] {
			alike(a, b, &reported, out)
		}
	}
}

// alike reports a against b when their bodies match: exactly at any size
// compared, or in shape when both are long enough for a shape to mean
// something. A pair is reported once.
alike :: proc(a, b: Owned, reported: ^map[string]bool, out: ^[dynamic]finding.Finding) {
	exact := false
	switch {
	case a.shape.exact == b.shape.exact:
		exact = true
	case a.shape.tokens >= min_shape_tokens &&
	     b.shape.tokens >= min_shape_tokens &&
	     a.shape.structural == b.shape.structural:
	case:
		return
	}
	key := fmt.tprintf("%s:%d|%s:%d", a.file, a.line, b.file, b.line)
	if reported[key] {
		return
	}
	reported[strings.clone(key, context.temp_allocator)] = true
	how :=
		"the same body, token for token," if exact else "the same shape of body, every name changed,"
	append(
		out,
		static(
			"duplicate-body",
			.Must_Fix if exact else .Consider,
			fmt.aprintf(
				"%s has %s as %s at %s:%d; one procedure written twice drifts into two",
				a.name,
				how,
				b.name,
				b.file,
				b.line,
			),
			fmt.aprintf("call %s, or lift what they share into one function both call", b.name),
			file = a.file,
			line = a.line,
			symbol = a.name,
		),
	)
}
