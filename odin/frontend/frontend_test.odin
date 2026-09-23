package frontend

import "core:os"
import "core:path/filepath"
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
