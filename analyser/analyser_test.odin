package analyser

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "jfm:sh"

import "../change"
import "../finding"
import "../tree"

@(test)
parse_go_build_reads_the_errors :: proc(t: ^testing.T) {
	out := "{\"ImportPath\":\"probe\",\"Action\":\"build-output\",\"Output\":\"# probe\\n\"}\n{\"ImportPath\":\"probe\",\"Action\":\"build-output\",\"Output\":\"./a.go:3:15: undefined: helper\\n\"}\n{\"ImportPath\":\"probe\",\"Action\":\"build-fail\"}\n"
	got := parse_go_build("/tree", out, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].file, "a.go")
		testing.expect_value(t, got[0].line, 3)
		testing.expect(t, got[0].fault)
		testing.expect_value(t, got[0].message, "undefined: helper")
	}
}

@(test)
parse_go_vet_reads_each_analyser :: proc(t: ^testing.T) {
	out := "# probe\n{\n\t\"probe\": {\n\t\t\"printf\": [{\"posn\": \"/tree/a.go:6:14\", \"message\": \"wrong type\"}],\n\t\t\"shadow\": [{\"posn\": \"/tree/b.go:9:2\", \"message\": \"declaration of err shadows\"}]\n\t}\n}\n# other\nvet: other/x.go:3: undefined: y\n"
	got := parse_go_vet("/tree", out, context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	by := make(map[string]Diagnostic, context.temp_allocator)
	for d in got {
		by[d.code] = d
	}
	testing.expect_value(t, by["printf"].file, "a.go")
	testing.expect_value(t, by["printf"].line, 6)
	testing.expect_value(t, by["printf"].severity, finding.Severity.Must_Fix)
	testing.expect_value(t, by["shadow"].severity, finding.Severity.Consider)
	Case :: struct {
		name: string,
		want: finding.Severity,
	}
	for c in ([]Case{{"printf", .Must_Fix}, {"nilness", .Must_Fix}, {"shadow", .Consider}, {"unusedwrite", .Consider}, {"rangeint", .Note}, {"stringscut", .Note}}) {
		testing.expectf(t, vet_severity(c.name) == c.want, "%s: %v", c.name, vet_severity(c.name))
	}
	chunks := split_json_objects(
		"# a\n{\"x\": {\"y\": \"}\"}}\nprose {not\n{\"z\": 1}\n",
		context.temp_allocator,
	)
	testing.expect_value(t, len(chunks), 2)
	if len(chunks) == 2 {
		testing.expect_value(t, chunks[0], `{"x": {"y": "}"}}`)
		testing.expect_value(t, chunks[1], `{"z": 1}`)
	}
	file, line := split_position("/tree/a.go:6:14")
	testing.expect_value(t, file, "/tree/a.go")
	testing.expect_value(t, line, 6)
	file, line = split_position("a.go:9")
	testing.expect_value(t, file, "a.go")
	testing.expect_value(t, line, 9)
}

@(test)
parse_odin_tells_vet_from_type_errors :: proc(t: ^testing.T) {
	out := `{"error_count": 3, "errors": [
	 {"type": "error", "pos": {"file": "/tree/lib/a.odin", "line": 6}, "msgs": ["'unused' declared but not used"]},
	 {"type": "warning", "pos": {"file": "/tree/lib/a.odin", "line": 4}, "msgs": ["Syntax Error: With '-strict-style' the attached brace style (1TBS) is enforced"]},
	 {"type": "error", "pos": {"file": "/tree/lib/a.odin", "line": 9}, "msgs": ["Undeclared name: foo"]}
	]}`
	got := parse_odin("/tree", out, context.temp_allocator)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0].code, "vet")
		testing.expect_value(t, got[0].severity, finding.Severity.Consider)
		testing.expect(t, !got[0].fault)
		testing.expect_value(t, got[1].code, "style")
		testing.expect_value(t, got[1].severity, finding.Severity.Note)
		testing.expect_value(t, got[2].code, "")
		testing.expect(t, got[2].fault)
		testing.expect_value(t, got[2].file, "lib/a.odin")
	}
}

@(test)
parse_tsc_ruff_mypy_cargo_semgrep :: proc(t: ^testing.T) {
	ts := parse_tsc(
		"/tree",
		"/tree/web",
		"src/a.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.\nnoise\n",
		context.temp_allocator,
	)
	testing.expect_value(t, len(ts), 1)
	if len(ts) == 1 {
		testing.expect_value(t, ts[0].file, "web/src/a.ts")
		testing.expect_value(t, ts[0].line, 12)
		testing.expect_value(t, ts[0].code, "TS2322")
		testing.expect(t, ts[0].fault)
	}
	rf, rerr := parse_ruff(
		"/tree",
		`[{"code":"F401","message":"os imported but unused","filename":"/tree/a.py","location":{"row":1,"column":8}},
	{"code":"E501","message":"Line too long","filename":"/tree/a.py","location":{"row":9,"column":89}}]`,
		context.temp_allocator,
	)
	testing.expect_value(t, rerr, "")
	testing.expect_value(t, len(rf), 2)
	if len(rf) == 2 {
		testing.expect_value(t, rf[0].severity, finding.Severity.Consider)
		testing.expect_value(t, rf[0].file, "a.py")
		testing.expect_value(t, rf[1].severity, finding.Severity.Note)
	}
	_, prose := parse_ruff("/tree", "not json", context.temp_allocator)
	testing.expect(t, prose != "", "prose was read as a report")
	my := parse_mypy(
		"/tree",
		`{"file": "a.py", "line": 4, "column": 4, "message": "Incompatible return value type", "hint": null, "code": "return-value", "severity": "error"}
{"file": "a.py", "line": 4, "column": 4, "message": "See the docs", "hint": null, "code": "return-value", "severity": "note"}
`,
		context.temp_allocator,
	)
	testing.expect_value(t, len(my), 2)
	if len(my) == 2 {
		testing.expect_value(t, my[0].severity, finding.Severity.Must_Fix)
		testing.expect_value(t, my[0].code, "return-value")
		testing.expect_value(t, my[1].severity, finding.Severity.Note)
	}
	cg := parse_cargo(
		"/tree",
		"/tree/crate",
		`{"reason":"compiler-artifact","target":{}}
{"reason":"compiler-message","message":{"level":"error","message":"cannot find value x","code":{"code":"E0425"},"spans":[{"file_name":"src/main.rs","line_start":3,"is_primary":false},{"file_name":"src/main.rs","line_start":4,"is_primary":true}]}}
{"reason":"compiler-message","message":{"level":"warning","message":"unused variable","code":{"code":"unused_variables"},"spans":[{"file_name":"src/lib.rs","line_start":7,"is_primary":true}]}}
{"reason":"compiler-message","message":{"level":"note","message":"aborting","code":null,"spans":[]}}
`,
		context.temp_allocator,
	)
	testing.expect_value(t, len(cg), 2)
	if len(cg) == 2 {
		testing.expect_value(t, cg[0].file, "crate/src/main.rs")
		testing.expect_value(t, cg[0].line, 4)
		testing.expect_value(t, cg[0].code, "E0425")
		testing.expect(t, cg[0].fault)
		testing.expect_value(t, cg[1].severity, finding.Severity.Consider)
		testing.expect(t, !cg[1].fault)
	}
	sg, serr := parse_semgrep(
		"/tree",
		`{"results":[
	 {"check_id":"go.lang.security.audit.crypto.math_random","path":"a.go","start":{"line":12},"extra":{"message":"math/rand is not secure\n","severity":"WARNING"}},
	 {"check_id":"python.lang.best-practice.open-never-closed","path":"/tree/b.py","start":{"line":3},"extra":{"message":"file never closed","severity":"ERROR"}},
	 {"check_id":"generic.note","path":"c.js","start":{"line":1},"extra":{"message":"fyi","severity":"INFO"}}
	],"errors":[]}`,
		context.temp_allocator,
	)
	testing.expect_value(t, serr, "")
	testing.expect_value(t, len(sg), 3)
	if len(sg) == 3 {
		testing.expect_value(t, sg[0].severity, finding.Severity.Consider)
		testing.expect_value(t, sg[0].message, "math/rand is not secure")
		testing.expect_value(t, sg[1].severity, finding.Severity.Must_Fix)
		testing.expect_value(t, sg[1].file, "b.py")
		testing.expect_value(t, sg[2].severity, finding.Severity.Note)
	}
	sc := parse_staticcheck(
		"/tree",
		`{"code":"SA4006","location":{"file":"/tree/a.go","line":5},"message":"never used"}
{"code":"compile","location":{"file":"/tree/a.go","line":1},"message":"broken"}
{"code":"ST1000","location":{"file":"/tree/a.go","line":1},"message":"style"}
`,
		context.temp_allocator,
	)
	testing.expect_value(t, len(sc), 2)
	if len(sc) == 2 {
		testing.expect_value(t, sc[0].severity, finding.Severity.Must_Fix)
		testing.expect_value(t, sc[1].severity, finding.Severity.Note)
	}
	testing.expect_value(t, staticcheck_severity("S1002"), finding.Severity.Consider)
	testing.expect_value(t, staticcheck_severity("U1000"), finding.Severity.Consider)
}

@(test)
a_run_past_the_timeout_is_not_waited_for :: proc(t: ^testing.T) {
	saved := timeout_seconds_override
	timeout_seconds_override = 1
	defer timeout_seconds_override = saved
	_, _, err := execute_both(".", "sleep", {"3"}, context.temp_allocator)
	testing.expect(t, strings.contains(err, "not waited for"), err)
	out, _, ok_err := execute_both(".", "echo", {"quick"}, context.temp_allocator)
	testing.expect_value(t, ok_err, "")
	testing.expect_value(t, out, "quick\n")
}

@(test)
nearest_walks_up :: proc(t: ^testing.T) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root, err := os.make_directory_temp(temp, "review-analyser-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(join(root, "web/src/deep")) == nil)
	testing.expect(
		t,
		os.write_entire_file(join(root, "web/tsconfig.json"), transmute([]byte)string("{}")) ==
		nil,
	)
	testing.expect_value(t, nearest(root, "web/src/deep", "tsconfig.json"), "web/tsconfig.json")
	testing.expect_value(t, nearest(root, "web/src/deep", "Cargo.toml"), "")
	testing.expect_value(t, relative("/tree", "/tree/a/b.go"), "a/b.go")
	testing.expect_value(t, relative("/tree", "./a.go"), "a.go")
	testing.expect_value(t, relative("/tree", "/elsewhere/a.go"), "/elsewhere/a.go")
	testing.expect_value(t, dir_of("a.go"), ".")
	testing.expect_value(t, dir_of("x/y/a.go"), "x/y")

	for path in ([]string{"a", "sidecar/govet", "sidecar/gofront"}) {
		testing.expect(t, os.make_directory_all(join(root, path)) == nil)
	}
	for path in ([]string{"go.mod", "sidecar/govet/go.mod"}) {
		testing.expect(
			t,
			os.write_entire_file(join(root, path), transmute([]byte)string("module x")) == nil,
		)
	}
	pkgs := go_packages(
		root,
		{"a/a.go", "sidecar/govet/main.go", "sidecar/gofront/main.go", "vendor/x/x.go"},
	)
	testing.expect_value(t, fmt.tprint(pkgs), `["./a", "./sidecar/gofront"]`)
}

// go_fixture is a module with one package: a printf fault on line 6 that
// vet sees, and nothing the compiler minds.
go_fixture :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	scratch, err := os.make_directory_temp(temp, "review-govet-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no scratch directory")
	}
	root = scratch
	git := proc(root: string, args: ..string) -> bool {
		argv := make([dynamic]string, context.temp_allocator)
		append(
			&argv,
			"git",
			"-c",
			"user.email=t@t",
			"-c",
			"user.name=t",
			"-c",
			"commit.gpgsign=false",
		)
		append(&argv, ..args)
		return sh.exec(argv[:], {dir = root}, context.temp_allocator).ok
	}
	ok = git(root, "init", "-q")
	ok &&=
		os.write_entire_file(
			join(root, "go.mod"),
			transmute([]byte)string("module probe\n\ngo 1.27.0\n"),
		) ==
		nil
	ok &&=
		os.write_entire_file(
			join(root, "a.go"),
			transmute([]byte)string(
				"package probe\n\nimport \"fmt\"\n\nfunc F() {\n\tfmt.Printf(\"%d\", \"s\")\n}\n",
			),
		) ==
		nil
	ok &&= git(root, "add", "go.mod", "a.go")
	return root, ok
}

@(test)
go_vet_reads_the_change :: proc(t: ^testing.T) {
	if !on_path("go") {
		testing.fail_now(t, "go is not on the path")
	}
	root, made := go_fixture(t)
	testing.expect(t, made)
	defer os.remove_all(root)
	c, gathered := change.gather("", root, context.temp_allocator)
	testing.expect(t, gathered)
	tr, at_ok := tree.at(root, "", context.temp_allocator)
	testing.expect(t, at_ok)
	findings := check(&c, tr, false, {go_build, go_vet}, context.temp_allocator)
	testing.expect_value(t, len(findings), 1)
	if len(findings) == 1 {
		testing.expect_value(t, findings[0].rule, "go-vet/printf")
		testing.expect_value(t, findings[0].file, "a.go")
		testing.expect_value(t, findings[0].line, 6)
		testing.expect_value(t, findings[0].severity, finding.Severity.Must_Fix)
		testing.expect(t, findings[0].verified)
	}
	_ = fmt.tprint(filepath.SEPARATOR)
}
