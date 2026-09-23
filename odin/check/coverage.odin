package check

// Two things about a change are visible only against the whole
// repository: whether anything refers to what it adds, and whether it
// added tests where the repository keeps them. Both are counted over the
// tree in memory.

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../change"
import "../finding"

@(private = "file")
unsearchable: map[string]bool
@(private = "file")
runtime_methods: map[string]bool

@(init)
init_coverage_lists :: proc "contextless" () {
	context = runtime.default_context()
	// The names the language calls rather than the code, and names too
	// short to search for.
	unsearchable = set(`main init TestMain _ default`)
	// The methods the standard library and its encoders call through an
	// interface or by reflection, so that nothing in the repository names
	// them and they are referenced all the same.
	runtime_methods = set(
		`String Error Format GoString MarshalJSON UnmarshalJSON MarshalText UnmarshalText
		MarshalBinary UnmarshalBinary MarshalYAML UnmarshalYAML GobEncode GobDecode Len Less Swap Read Write
		Close Seek ReadFrom WriteTo ServeHTTP Scan Value Is As Unwrap Compare Equal Hash`,
	)
}

// check_unreferenced reports a new declaration nothing in the repository
// refers to: not the change, not the rest of the tree. It is written and
// waiting, and what waits drifts. The name is searched as a whole word
// over every text file, so a use from a template or a script counts. One
// finding per file, naming what it declares and nothing refers to.
check_unreferenced :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	unused := make(map[string][dynamic]change.Symbol, context.temp_allocator)
	for sym in s.c.symbols {
		if is_test_file(sym.file) ||
		   sym.kind == "field" ||
		   unsearchable[sym.name] ||
		   called_by_the_runtime(sym) {
			continue
		}
		if referenced(sym, s.sources) {
			continue
		}
		list := unused[sym.file]
		if list.allocator.procedure == nil {
			list = make([dynamic]change.Symbol, context.temp_allocator)
		}
		append(&list, sym)
		unused[sym.file] = list
	}
	for file in sorted_keys(unused) {
		symbols := unused[file]
		names := make([dynamic]string, context.temp_allocator)
		for sym, i in symbols {
			if i == 8 {
				append(&names, fmt.tprintf("and %d more", len(symbols) - 8))
				break
			}
			append(&names, sym.name)
		}
		append(
			out,
			static(
				"new-symbol-unreferenced",
				.Consider,
				fmt.aprintf(
					"nothing in the repository refers to %s but the declaration%s in %s; code written for a caller that does not exist yet is a guess about what the caller will need",
					strings.join(names[:], ", ", context.temp_allocator),
					plural(len(symbols)),
					file,
				),
				"use it, or leave it out until something does",
				file = file,
				line = symbols[0].line,
				symbol = symbols[0].name,
			),
		)
	}
}

// called_by_the_runtime is whether a symbol is called by something
// outside the repository's text: a method an encoder or interface reaches
// for, or a function cgo exports to the host under //export.
called_by_the_runtime :: proc(sym: change.Symbol) -> bool {
	if sym.kind == "func" && runtime_methods[sym.name] {
		return true
	}
	if strings.has_suffix(sym.file, ".go") {
		rest := sym.doc
		for line in strings.split_lines_iterator(&rest) {
			if strings.trim_space(line) ==
			   strings.concatenate({"export ", sym.name}, context.temp_allocator) {
				return true
			}
		}
	}
	return false
}

// referenced is whether the name appears as a whole word anywhere but on
// its own declaration line or in a comment. A Go doc comment opens with
// the name it documents, and a comment is not a caller.
referenced :: proc(sym: change.Symbol, sources: map[string][]byte) -> bool {
	if len(sym.name) < 2 {
		return true // Too short to search for honestly.
	}
	for file, data in sources {
		text := string(data)
		offset := 0
		for {
			i := strings.index(text[offset:], sym.name)
			if i < 0 {
				break
			}
			at := offset + i
			offset = at + len(sym.name)
			if !word_boundary(text, at, len(sym.name)) {
				continue
			}
			if file == sym.file && line_of(text, at) == sym.line {
				continue
			}
			if in_comment(text, at) {
				continue
			}
			return true
		}
	}
	return false
}

// word_boundary is whether the match at i of length n is bounded by
// non-identifier characters on both sides.
word_boundary :: proc(text: string, i, n: int) -> bool {
	before := i == 0 || !ident_char(text[i - 1])
	after := i + n >= len(text) || !ident_char(text[i + n])
	return before && after
}

ident_char :: proc(b: byte) -> bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// in_comment is whether the offset sits on a line that is a comment by
// the shapes the tool's languages share, or after a line comment's
// opening.
in_comment :: proc(text: string, offset: int) -> bool {
	start := strings.last_index_byte(text[:offset], '\n') + 1
	line := text[start:offset]
	head := strings.concatenate(
		{line, text[offset:min(offset + 1, len(text))]},
		context.temp_allocator,
	)
	if change.is_comment_line(strings.trim_space(head)) {
		return true
	}
	return strings.contains(line, "//") || strings.contains(line, "/*")
}

// line_of is the 1-based line the offset falls on.
line_of :: proc(text: string, offset: int) -> int {
	return 1 + strings.count(text[:offset], "\n")
}

// test_floor_lines is the size of change, in lines added to code that is
// not a test, from which a change owes a test where the repository keeps
// them.
test_floor_lines :: 50

// check_code_without_tests reports a change that adds a body of code to a
// repository that has tests, and touches none of them.
check_code_without_tests :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	lines := 0
	for file, l in s.c.added {
		if change.is_code_file(file) && !is_test_file(file) {
			lines += len(l)
		}
	}
	if lines < test_floor_lines {
		return
	}
	for f in s.c.files {
		if is_test_file(f) {
			return
		}
	}
	tested := 0
	for f in s.files {
		if is_test_file(f) {
			tested += 1
		}
	}
	if tested == 0 {
		return // A repository without tests is not asked to start here.
	}
	append(
		out,
		static(
			"code-without-tests",
			.Consider,
			fmt.aprintf(
				"the change adds %d lines of code and touches no test, in a repository that keeps %d test files; what the change does is asserted nowhere",
				lines,
				tested,
			),
			"add or extend the test that would fail without this change",
		),
	)
}
