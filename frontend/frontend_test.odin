package frontend

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

write_temp :: proc(t: ^testing.T, name, src: string) -> string {
	dir, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil, "temp directory")
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, join_err == nil, "join")
	testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil, "write fixture")
	return path
}

@(test)
go_sidecar_lists_declarations :: proc(t: ^testing.T) {
	if !installed(.Go) {
		testing.fail_now(
			t,
			"review-go is not on the path: go build -o ~/go/bin/review-go ./sidecar/gofront",
		)
	}
	path := write_temp(
		t,
		"review_frontend_fixture.go",
		`package fixture

import "fmt"

// Limit bounds the work.
const Limit = 3

type Point struct{ X int }

func helper() { fmt.Println(Limit) }

func TestHelper(t *testing.T) { helper() }
`,
	)
	defer os.remove(path)

	out, err := scan(.Go, {path}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, len(out.files), 1)
	file := out.files[0]
	testing.expect_value(t, file.name, path)
	testing.expect_value(t, file.pkg, "fixture")
	testing.expect_value(t, file.error, "")
	testing.expect_value(t, len(file.imports), 1)
	testing.expect_value(t, file.imports[0], "fmt")

	by_name := make(map[string]Decl, context.temp_allocator)
	for decl in file.decls {
		by_name[decl.name] = decl
	}
	testing.expect_value(t, len(by_name), 5)
	testing.expect_value(t, by_name["Limit"].kind, "const")
	testing.expect_value(t, by_name["Limit"].line, 6)
	testing.expect_value(t, by_name["Limit"].doc, "Limit bounds the work.")
	testing.expect_value(t, by_name["Limit"].exported, true)
	testing.expect_value(t, by_name["Point"].kind, "type")
	testing.expect_value(t, by_name["X"].kind, "field")
	testing.expect_value(t, by_name["helper"].exported, false)
	testing.expect_value(t, by_name["helper"].text, "func helper() { fmt.Println(Limit) }")
	testing.expect_value(t, by_name["TestHelper"].test, true)

	found := tests(file, context.temp_allocator)
	testing.expect_value(t, len(found), 1)
	testing.expect_value(t, found[0].name, "TestHelper")
	testing.expect_value(t, len(file.comments), 1)
	testing.expect_value(t, file.comments[0].line, 5)
}

@(test)
go_sidecar_reports_a_file_it_cannot_parse :: proc(t: ^testing.T) {
	if !installed(.Go) {
		testing.fail_now(t, "review-go is not on the path")
	}
	path := write_temp(t, "review_frontend_broken.go", "package x\nfunc {\n")
	defer os.remove(path)
	out, err := scan(.Go, {path}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, len(out.files), 1)
	testing.expect(t, len(out.files[0].error) > 0, "a parse error is reported")
	testing.expect_value(t, len(out.files[0].decls), 0)
}

@(test)
scan_of_nothing_asks_nothing :: proc(t: ^testing.T) {
	out, err := scan(.Go, {}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, len(out.files), 0)
}

write_fixture :: proc(t: ^testing.T, name, src: string) -> string {
	return write_temp(t, name, src)
}

@(test)
ast_grep_reads_typescript :: proc(t: ^testing.T) {
	if !installed(.Script) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	path := write_fixture(
		t,
		"review_grep_fixture.ts",
		`import { x } from "y";

// Limit bounds the work.
export const limit: number = 3;
const hidden = 4;
export type Pair = [number, number];
interface Shape { size: number }
export function read(a: string): number {
  const inner = 1;
  return inner;
}
export default function main() {}
describe('icons', () => {
  it('decodes the largest', () => { expect(size).toBe(1); });
  test.skip("reads a binary", () => {});
});
`,
	)
	defer os.remove(path)
	out, err := scan(.Script, {path}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, len(out.files), 1)
	by := make(map[string]Decl, context.temp_allocator)
	for d in out.files[0].decls {
		by[d.name] = d
	}
	testing.expect_value(t, len(by), 8)
	testing.expect_value(t, by["limit"].kind, "value")
	testing.expect(t, by["limit"].exported)
	testing.expect_value(t, by["limit"].doc, "Limit bounds the work.")
	testing.expect_value(t, by["limit"].line, 4)
	testing.expect(t, !by["hidden"].exported)
	testing.expect_value(t, by["Pair"].kind, "type")
	testing.expect_value(t, by["Shape"].kind, "type")
	testing.expect_value(t, by["read"].kind, "func")
	testing.expect_value(t, by["read"].end_line, 11)
	testing.expect_value(t, by["main"].kind, "func")
	testing.expect(t, by["decodes the largest"].test)
	testing.expect(t, by["reads a binary"].test)
	_, nested := by["inner"]
	testing.expect(t, !nested, "a declaration inside a body is not top level")
}

@(test)
ast_grep_reads_python_and_rust :: proc(t: ^testing.T) {
	if !installed(.Python) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	py := write_fixture(
		t,
		"review_grep_fixture.py",
		`"""Icons."""
MAX_ICONS = 12
_hidden: int = 4

# Reads the icons a file holds.
def read_icons(src):
    inner = 1
    def nested():
        return inner
    return []

class Reader:
    size = 0
    def method(self):
        return 1

def test_smoke():
    read_icons("y")
`,
	)
	defer os.remove(py)
	out, err := scan(.Python, {py}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	by := make(map[string]Decl, context.temp_allocator)
	for d in out.files[0].decls {
		by[d.name] = d
	}
	testing.expect_value(t, len(by), 5)
	testing.expect_value(t, by["MAX_ICONS"].kind, "value")
	testing.expect(t, by["MAX_ICONS"].exported)
	testing.expect(t, !by["_hidden"].exported)
	testing.expect_value(t, by["read_icons"].kind, "func")
	testing.expect_value(t, by["read_icons"].doc, "Reads the icons a file holds.")
	testing.expect_value(t, by["Reader"].kind, "type")
	testing.expect(t, by["test_smoke"].test)
	testing.expect_value(t, by["test_smoke"].kind, "func")

	rs := write_fixture(
		t,
		"review_grep_fixture.rs",
		`pub const LIMIT: usize = 3;
static mut COUNT: i32 = 0;

/// A shape.
pub struct Shape { size: usize }

impl Shape {
    pub fn area(&self) -> usize { self.size }
    fn hidden(&self) -> usize { 0 }
}

#[test]
fn reads_shapes() {
    assert_eq!(count(), 1);
}
`,
	)
	defer os.remove(rs)
	out, err = scan(.Rust, {rs}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	clear(&by)
	for d in out.files[0].decls {
		by[d.name] = d
	}
	testing.expect_value(t, len(by), 6)
	testing.expect(t, by["LIMIT"].exported)
	testing.expect(t, !by["COUNT"].exported)
	testing.expect_value(t, by["Shape"].kind, "type")
	testing.expect_value(t, by["Shape"].doc, "A shape.")
	testing.expect(t, by["area"].exported)
	testing.expect(t, !by["hidden"].exported)
	testing.expect(t, by["reads_shapes"].test)
	testing.expect_value(t, by["reads_shapes"].end_line, 15)
}

@(test)
doc_above_reads_the_block :: proc(t: ^testing.T) {
	lines := []string{"x", "/** Two", " * lines */", "// and one", "const a = 1"}
	testing.expect_value(t, doc_above(lines, 5, context.temp_allocator), "Two lines and one")
	testing.expect_value(t, doc_above(lines, 1, context.temp_allocator), "")
	testing.expect_value(t, scratch_ext(.Script, "a/b.mjs"), ".js")
	testing.expect_value(t, scratch_ext(.Bash, "bin/deploy"), ".sh")
	testing.expect_value(t, grammar_of("a.tsx"), "tsx")
	testing.expect(t, typed("export type $N = $$$B"))
	testing.expect(t, !typed("export const $N = $$$V"))
}

@(test)
ast_grep_reads_bash :: proc(t: ^testing.T) {
	if !installed(.Bash) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	sh := write_fixture(
		t,
		"review_grep_fixture.sh",
		`#!/usr/bin/env bash
set -euo pipefail

readonly RETRIES=3
TARGET=production
export DESTINATION="/srv"

# deploy sends one artefact and says what the host said.
deploy() {
  local artefact=$1
  echo "sending $artefact"
}

function rollback {
  echo back
}
`,
	)
	defer os.remove(sh)
	out, err := scan(.Bash, {sh}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, out.files[0].error, "")
	by := make(map[string]Decl, context.temp_allocator)
	for d in out.files[0].decls {
		by[d.name] = d
	}
	// The three top-level values, and both spellings of a function. The
	// local inside deploy is not a declaration of the script's.
	testing.expect_value(t, len(by), 5)
	testing.expect_value(t, by["RETRIES"].kind, "value")
	testing.expect_value(t, by["TARGET"].kind, "value")
	testing.expect_value(t, by["DESTINATION"].kind, "value")
	testing.expect_value(t, by["deploy"].kind, "func")
	testing.expect(t, by["deploy"].exported)
	testing.expect_value(t, by["deploy"].doc, "deploy sends one artefact and says what the host said.")
	testing.expect_value(t, by["deploy"].end_line, 12)
	testing.expect_value(t, by["rollback"].kind, "func")
}

@(test)
ast_grep_declines_a_bash_file_it_cannot_parse :: proc(t: ^testing.T) {
	if !installed(.Bash) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	// An extglob pattern defeats the grammar, and the error node it
	// leaves swallows the function below it. A partial reading is worse
	// than none, so the file is declined whole.
	sh := write_fixture(
		t,
		"review_grep_broken.sh",
		`#!/usr/bin/env bash
print_saved() {
  for f in "${1}"?(.+([0-9])); do
    printf '%s\0' "$f"
  done
}

cache_tar() {
  echo tar
}
`,
	)
	defer os.remove(sh)
	out, err := scan(.Bash, {sh}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, out.files[0].error, "ast-grep could not parse it")
	testing.expect_value(t, len(out.files[0].decls), 0)
}

@(test)
ast_grep_reads_java :: proc(t: ^testing.T) {
	if !installed(.Java) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	java := write_fixture(
		t,
		"review_grep_fixture.java",
		`package dev.example;

/** Quarry digs stone. */
public final class Quarry {
    // LIMIT caps the depth.
    static final int LIMIT = 3;
    private int depth;

    /**
     * Builds one at a depth.
     */
    public Quarry(int depth) { this.depth = depth; }

    @Override
    protected String toString() {
        Runnable r = new Runnable() { public void run() {} };
        return "quarry";
    }

    @Test
    void digsDown() {
        assertEquals(1, new Quarry(1).depth);
    }

    @org.junit.jupiter.params.ParameterizedTest
    @ValueSource(ints = {1, 2})
    void digsMany(int n) { assertTrue(n > 0); }

    void helper() {}

    record Point(int x, int y) {}
    interface Shape { double area(); }
    enum Colour { RED, GREEN }
    @interface Marker {}
}
`,
	)
	defer os.remove(java)
	out, err := scan(.Java, {java}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, out.files[0].error, "")
	by := make(map[string][dynamic]Decl, context.temp_allocator)
	for d in out.files[0].decls {
		if d.name not_in by {
			by[d.name] = make([dynamic]Decl, context.temp_allocator)
		}
		append(&by[d.name], d)
	}
	// The class and its constructor share a name; run, in the anonymous
	// class, is a local and left out.
	testing.expect_value(t, len(out.files[0].decls), 13)
	testing.expect(t, "run" not_in by)
	class, ctor := by["Quarry"][0], by["Quarry"][1]
	testing.expect_value(t, class.kind, "type")
	testing.expect_value(t, class.doc, "Quarry digs stone.")
	testing.expect(t, class.exported)
	testing.expect_value(t, ctor.kind, "func")
	testing.expect_value(t, ctor.doc, "Builds one at a depth.")
	testing.expect_value(t, ctor.line, 12)
	testing.expect_value(t, by["LIMIT"][0].kind, "value")
	testing.expect_value(t, by["LIMIT"][0].doc, "LIMIT caps the depth.")
	testing.expect(t, !by["LIMIT"][0].exported)
	testing.expect_value(t, by["depth"][0].kind, "field")
	// An annotated method sits on its name's line, its body runs from
	// there, and its audience is read past the annotation.
	to_string := by["toString"][0]
	testing.expect_value(t, to_string.line, 15)
	testing.expect_value(t, to_string.end_line, 18)
	testing.expect_value(t, to_string.text, "protected String toString() {")
	testing.expect(t, to_string.exported)
	testing.expect(t, !to_string.test)
	testing.expect(t, strings.has_prefix(to_string.body, "protected String toString()"))
	testing.expect(t, by["digsDown"][0].test)
	testing.expect_value(t, by["digsDown"][0].line, 21)
	testing.expect_value(t, by["digsDown"][0].end_line, 23)
	testing.expect(t, by["digsMany"][0].test)
	testing.expect_value(t, by["digsMany"][0].line, 27)
	testing.expect(t, !by["helper"][0].test)
	for name in ([]string{"Point", "Shape", "Colour", "Marker"}) {
		testing.expectf(t, by[name][0].kind == "type", "%s is a type", name)
	}
	// An interface and its method share a line and are both kept.
	testing.expect_value(t, by["area"][0].kind, "func")
	testing.expect_value(t, by["area"][0].line, by["Shape"][0].line)
}

@(test)
ast_grep_declines_a_java_file_it_cannot_parse :: proc(t: ^testing.T) {
	if !installed(.Java) {
		testing.fail_now(t, "ast-grep is not on the path")
	}
	java := write_fixture(
		t,
		"review_grep_broken.java",
		`class Broken {
    void f() { int x = ; }
    void g() {}
}
`,
	)
	defer os.remove(java)
	out, err := scan(.Java, {java}, context.temp_allocator)
	testing.expect_value(t, err, Scan_Error.None)
	testing.expect_value(t, out.files[0].error, "ast-grep could not parse it")
	testing.expect_value(t, len(out.files[0].decls), 0)
}
