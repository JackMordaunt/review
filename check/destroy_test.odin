package check

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../finding"
import "../frontend"

// destroyed stages an Odin package of one file, a/a.odin, over a
// repository whose first commit holds base there when base is not empty,
// and returns what check_destroy_incomplete finds in the staged change.
destroyed :: proc(t: ^testing.T, base, src: string) -> []finding.Finding {
	if !frontend.installed(.Odin) {
		testing.fail_now(t, "odin-review-extract is not on the path")
	}
	root, made := new_repo(t)
	testing.expect(t, made)
	defer os.remove_all(root)
	testing.expect(
		t,
		os.make_directory_all(filepath.join({root, "a"}, context.temp_allocator) or_else "") ==
		nil,
	)
	if base != "" {
		testing.expect(t, write(root, "a/a.odin", base))
		testing.expect(t, git(root, "add", "a/a.odin"))
		testing.expect(t, git(root, "commit", "-q", "-m", "a: add a"))
	}
	testing.expect(t, write(root, "a/a.odin", src))
	testing.expect(t, git(root, "add", "a/a.odin"))
	_, s := staged(t, root)
	return collect(s, check_destroy_incomplete, context.temp_allocator)
}

@(test)
destroy_incomplete_reports_a_forgotten_field :: proc(t: ^testing.T) {
	got := destroyed(
		t,
		"",
		`package a

Index :: struct {
	names: [dynamic]string,
	by:    map[string]int,
	count: int,
}

index_destroy :: proc(x: ^Index) {
	delete(x.names)
}
`,
	)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].rule, "odin-destroy-incomplete")
		testing.expect_value(t, got[0].severity, finding.Severity.Consider)
		testing.expect_value(t, got[0].file, "a/a.odin")
		testing.expect_value(t, got[0].line, 5)
		testing.expect_value(
			t,
			got[0].message,
			"field `by` of `Index` (map[string]int) is never released in `index_destroy`; free it there or mark it borrowed",
		)
	}
}

@(test)
destroy_incomplete_spares_a_struct_freed_whole :: proc(t: ^testing.T) {
	// Every field freed, one through using; a nested struct handed to its
	// own destroy; a struct whose arena is destroyed with its strings in
	// it.
	got := destroyed(
		t,
		"",
		`package a

import "core:mem/virtual"

Inner :: struct {
	s: string,
}

destroy_inner :: proc(i: ^Inner) {
	delete(i.s)
}

Index :: struct {
	names: [dynamic]string,
	by:    map[string]int,
	inner: Inner,
}

index_destroy :: proc(using x: ^Index) {
	delete(names)
	delete(x^.by)
	destroy_inner(&x.inner)
}

Table :: struct {
	arena: virtual.Arena,
	rows:  []string,
	name:  string,
}

table_free :: proc(t: ^Table) {
	virtual.arena_destroy(&t.arena)
}

Loose :: struct {
	s: string,
}
`,
	)
	testing.expect_value(t, len(got), 0)
}

@(test)
destroy_incomplete_reads_nested_ownership :: proc(t: ^testing.T) {
	// A struct field owns memory when its type has a release of its own.
	got := destroyed(
		t,
		"",
		`package a

Inner :: struct {
	s: string,
}

inner_deinit :: proc(i: ^Inner) {
	delete(i.s)
}

Outer :: struct {
	inner: Inner,
}

outer_destroy :: proc(o: ^Outer) {
}
`,
	)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].symbol, "Outer.inner")
	}
}

@(test)
destroy_incomplete_spares_legacy_code :: proc(t: ^testing.T) {
	legacy := `package a

Index :: struct {
	names: [dynamic]string,
	by:    map[string]int,
}

index_destroy :: proc(x: ^Index) {
	delete(x.names)
}
`
	untouched := destroyed(
		t,
		legacy,
		strings.concatenate({legacy, "\nsize :: proc(x: ^Index) -> int {\n\treturn len(x.names)\n}\n"}, context.temp_allocator),
	)
	testing.expect_value(t, len(untouched), 0)

	// A change to the destroy procedure is a change to what it frees, and
	// the fields it still misses are read again.
	touched := destroyed(
		t,
		legacy,
		strings.concatenate(
			{
				strings.trim_suffix(legacy, "}\n"),
				"\tclear(&x.names)\n}\n",
			},
			context.temp_allocator,
		),
	)
	testing.expect_value(t, len(touched), 1)
	if len(touched) == 1 {
		testing.expect_value(t, touched[0].symbol, "Index.by")
		testing.expect_value(t, touched[0].line, 5)
	}
}

@(test)
snake_case_reads_both_habits :: proc(t: ^testing.T) {
	testing.expect_value(t, snake_case("Index"), "index")
	testing.expect_value(t, snake_case("Index_Entry"), "index_entry")
	testing.expect_value(t, snake_case("IndexEntry"), "index_entry")
	testing.expect_value(t, snake_case("HTTP_Server"), "http_server")
}
