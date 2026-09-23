package main

// The analysers are the repository's own compilers, asked for JSON. These
// tests hold what review does with their answers: a fault is the change's
// wherever it lands, an opinion only on a line the change added, and each
// tool's output is read into the same shape.

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func needGo(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go is not installed")
	}
}

// goFixture is a module with one package: a printf fault on line 6 that vet
// sees, and nothing the compiler minds.
func goFixture(t *testing.T) *repo {
	t.Helper()
	r := newRepo(t)
	r.write("go.mod", "module probe\n\ngo 1.27.0\n")
	r.write("a.go", "package probe\n\nimport \"fmt\"\n\nfunc F() {\n\tfmt.Printf(\"%d\", \"s\")\n}\n")
	return r
}

func TestGoVetReadsTheChange(t *testing.T) {
	needGo(t)
	r := goFixture(t)
	r.stage("go.mod", "a.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := checkAnalysers(r.Root, "", change, goBuild, goVet)
	if len(findings) != 1 || findings[0].Rule != "go-vet/printf" || findings[0].File != "a.go" || findings[0].Line != 6 || findings[0].Severity != MustFix {
		t.Fatalf("got %v", findings)
	}
}

// An opinion on a line the change did not add is the analyser's, not the
// change's.
func TestGoVetKeepsToTheChange(t *testing.T) {
	needGo(t)
	r := goFixture(t)
	r.commit("first", "go.mod", "a.go")
	r.write("a.go", "package probe\n\nimport \"fmt\"\n\nfunc F() {\n\tfmt.Printf(\"%d\", \"s\")\n}\n\nfunc G() {}\n")
	r.stage("a.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if findings := checkAnalysers(r.Root, "", change, goVet); len(findings) != 0 {
		t.Errorf("got %v, want the old fault left alone", findings)
	}
}

// A build error is the change's wherever it lands: the package the change
// touched no longer compiles.
func TestGoBuildReportsAFaultAnywhereInThePackage(t *testing.T) {
	needGo(t)
	r := newRepo(t)
	r.write("go.mod", "module probe\n\ngo 1.27.0\n")
	r.write("a.go", "package probe\n\nfunc F() int { return helper() }\n")
	r.write("b.go", "package probe\n\nfunc helper() int { return 1 }\n")
	r.commit("first", "go.mod", "a.go", "b.go")
	// The change removes the helper; the error lands in the unchanged file.
	r.write("b.go", "package probe\n")
	r.stage("b.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := checkAnalysers(r.Root, "", change, goBuild, goVet)
	if len(findings) != 1 || findings[0].Rule != "go-build" || findings[0].File != "a.go" || findings[0].Line != 3 || findings[0].Severity != MustFix {
		t.Fatalf("got %v", findings)
	}
	if !strings.Contains(findings[0].Message, "undefined: helper") {
		t.Errorf("message %q", findings[0].Message)
	}
}

// A range is analysed on the tree it arrived at, not the working tree.
func TestGoVetReadsARange(t *testing.T) {
	needGo(t)
	r := goFixture(t)
	r.write("a.go", "package probe\n")
	r.commit("first", "go.mod", "a.go")
	r.write("a.go", "package probe\n\nimport \"fmt\"\n\nfunc F() {\n\tfmt.Printf(\"%d\", \"s\")\n}\n")
	rev := r.commit("second", "a.go")
	r.write("a.go", "package probe\n") // The working tree is clean; the range is not.
	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := checkAnalysers(r.Root, rev+"^.."+rev, change, goVet)
	if len(findings) != 1 || findings[0].Rule != "go-vet/printf" {
		t.Fatalf("got %v", findings)
	}
}

func TestOdinCheckReadsTheChange(t *testing.T) {
	if _, err := exec.LookPath("odin"); err != nil {
		t.Skip("odin is not installed")
	}
	r := newRepo(t)
	r.write("lib/lib.odin", "package lib\n\ncount :: proc(xs: []int) -> int {\n\tunused := 3\n\treturn len(xs)\n}\n")
	r.stage("lib/lib.odin")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := checkAnalysers(r.Root, "", change, odinCheck)
	if len(findings) != 1 || findings[0].Rule != "odin-check/vet" || findings[0].File != "lib/lib.odin" || findings[0].Line != 4 || findings[0].Severity != Consider {
		t.Fatalf("got %v", findings)
	}
}

func TestParseGoBuild(t *testing.T) {
	out := []byte(`{"ImportPath":"probe","Action":"build-output","Output":"# probe\n"}
{"ImportPath":"probe","Action":"build-output","Output":"./a.go:3:15: undefined: helper\n"}
{"ImportPath":"probe","Action":"build-fail"}
`)
	got := parseGoBuild("/tree", out)
	if len(got) != 1 || got[0].File != "a.go" || got[0].Line != 3 || !got[0].Fault || got[0].Message != "undefined: helper" {
		t.Errorf("got %+v", got)
	}
}

func TestParseGoVet(t *testing.T) {
	out := []byte("# probe\n{\n\t\"probe\": {\n\t\t\"printf\": [{\"posn\": \"/tree/a.go:6:14\", \"message\": \"wrong type\"}],\n\t\t\"shadow\": [{\"posn\": \"/tree/b.go:9:2\", \"message\": \"declaration of err shadows\"}]\n\t}\n}\n# other\nvet: other/x.go:3: undefined: y\n")
	got := parseGoVet("/tree", out)
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	by := map[string]Diagnostic{}
	for _, d := range got {
		by[d.Code] = d
	}
	if by["printf"].File != "a.go" || by["printf"].Line != 6 || by["printf"].Severity != MustFix {
		t.Errorf("printf: %+v", by["printf"])
	}
	if by["shadow"].Severity != Consider {
		t.Errorf("shadow: %+v", by["shadow"])
	}
}

func TestVetSeverity(t *testing.T) {
	for name, want := range map[string]Severity{"printf": MustFix, "nilness": MustFix, "shadow": Consider, "unusedwrite": Consider, "rangeint": Note, "stringscut": Note} {
		if got := vetSeverity(name); got != want {
			t.Errorf("%s: %s, want %s", name, got, want)
		}
	}
}

func TestParseOdin(t *testing.T) {
	out := []byte(`{"error_count": 3, "errors": [
	 {"type": "error", "pos": {"file": "/tree/lib/a.odin", "line": 6}, "msgs": ["'unused' declared but not used"]},
	 {"type": "warning", "pos": {"file": "/tree/lib/a.odin", "line": 4}, "msgs": ["Syntax Error: With '-strict-style' the attached brace style (1TBS) is enforced"]},
	 {"type": "error", "pos": {"file": "/tree/lib/a.odin", "line": 9}, "msgs": ["Undeclared name: foo"]}
	]}`)
	got := parseOdin("/tree", out)
	if len(got) != 3 {
		t.Fatalf("got %+v", got)
	}
	if got[0].Code != "vet" || got[0].Severity != Consider || got[0].Fault {
		t.Errorf("vet: %+v", got[0])
	}
	if got[1].Code != "style" || got[1].Severity != Note || got[1].Fault {
		t.Errorf("style: %+v", got[1])
	}
	if got[2].Code != "" || got[2].Severity != MustFix || !got[2].Fault || got[2].File != "lib/a.odin" {
		t.Errorf("type error: %+v", got[2])
	}
}

func TestParseTsc(t *testing.T) {
	out := []byte("src/a.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.\nnoise\n")
	got := parseTsc("/tree", "/tree/web", out)
	if len(got) != 1 || got[0].File != "web/src/a.ts" || got[0].Line != 12 || got[0].Code != "TS2322" || !got[0].Fault {
		t.Errorf("got %+v", got)
	}
}

func TestParseRuff(t *testing.T) {
	out := []byte(`[{"code":"F401","message":"os imported but unused","filename":"/tree/a.py","location":{"row":1,"column":8}},
	{"code":"E501","message":"Line too long","filename":"/tree/a.py","location":{"row":9,"column":89}}]`)
	got, err := parseRuff("/tree", out)
	if err != nil || len(got) != 2 {
		t.Fatalf("got %+v, %v", got, err)
	}
	if got[0].Severity != Consider || got[0].File != "a.py" || got[1].Severity != Note {
		t.Errorf("got %+v", got)
	}
	if _, err := parseRuff("/tree", []byte("not json")); err == nil {
		t.Error("prose was read as a report")
	}
}

func TestParseMypy(t *testing.T) {
	out := []byte(`{"file": "a.py", "line": 4, "column": 4, "message": "Incompatible return value type", "hint": null, "code": "return-value", "severity": "error"}
{"file": "a.py", "line": 4, "column": 4, "message": "See the docs", "hint": null, "code": "return-value", "severity": "note"}
`)
	got := parseMypy("/tree", out)
	if len(got) != 2 || got[0].Severity != MustFix || got[0].Code != "return-value" || got[1].Severity != Note {
		t.Errorf("got %+v", got)
	}
}

func TestParseCargo(t *testing.T) {
	out := []byte(`{"reason":"compiler-artifact","target":{}}
{"reason":"compiler-message","message":{"level":"error","message":"cannot find value x","code":{"code":"E0425"},"spans":[{"file_name":"src/main.rs","line_start":3,"is_primary":false},{"file_name":"src/main.rs","line_start":4,"is_primary":true}]}}
{"reason":"compiler-message","message":{"level":"warning","message":"unused variable","code":{"code":"unused_variables"},"spans":[{"file_name":"src/lib.rs","line_start":7,"is_primary":true}]}}
{"reason":"compiler-message","message":{"level":"note","message":"aborting","code":null,"spans":[]}}
`)
	got := parseCargo("/tree", "/tree/crate", out)
	if len(got) != 2 {
		t.Fatalf("got %+v", got)
	}
	if got[0].File != "crate/src/main.rs" || got[0].Line != 4 || got[0].Code != "E0425" || !got[0].Fault {
		t.Errorf("error: %+v", got[0])
	}
	if got[1].Severity != Consider || got[1].Fault {
		t.Errorf("warning: %+v", got[1])
	}
}

func TestSplitJSONObjects(t *testing.T) {
	chunks := splitJSONObjects([]byte("# a\n{\"x\": {\"y\": \"}\"}}\nprose {not\n{\"z\": 1}\n"))
	if len(chunks) != 2 || string(chunks[0]) != `{"x": {"y": "}"}}` || string(chunks[1]) != `{"z": 1}` {
		t.Errorf("got %q", chunks)
	}
}

func TestNearest(t *testing.T) {
	r := newRepo(t)
	r.write("web/tsconfig.json", "{}")
	r.write("web/src/deep/a.ts", "")
	if got := nearest(r.Root, "web/src/deep", "tsconfig.json"); got != "web/tsconfig.json" {
		t.Errorf("got %q", got)
	}
	if got := nearest(r.Root, "web/src/deep", "Cargo.toml"); got != "" {
		t.Errorf("got %q, want nothing", got)
	}
}

func TestParseSemgrep(t *testing.T) {
	out := []byte(`{"results":[
	 {"check_id":"go.lang.security.audit.crypto.math_random","path":"a.go","start":{"line":12},"extra":{"message":"math/rand is not secure\n","severity":"WARNING"}},
	 {"check_id":"python.lang.best-practice.open-never-closed","path":"/tree/b.py","start":{"line":3},"extra":{"message":"file never closed","severity":"ERROR"}},
	 {"check_id":"generic.note","path":"c.js","start":{"line":1},"extra":{"message":"fyi","severity":"INFO"}}
	],"errors":[]}`)
	got, err := parseSemgrep("/tree", out)
	if err != nil || len(got) != 3 {
		t.Fatalf("got %+v, %v", got, err)
	}
	if got[0].Severity != Consider || got[0].Code != "go.lang.security.audit.crypto.math_random" || got[0].Message != "math/rand is not secure" {
		t.Errorf("warning: %+v", got[0])
	}
	if got[1].Severity != MustFix || got[1].File != "b.py" {
		t.Errorf("error: %+v", got[1])
	}
	if got[2].Severity != Note || got[2].Fault {
		t.Errorf("info: %+v", got[2])
	}
}

func TestSemgrepConfig(t *testing.T) {
	dir := t.TempDir()
	if got := semgrepConfig(dir); got != "p/default" {
		t.Errorf("got %q", got)
	}
	r := newRepo(t)
	r.write(".semgrep.yml", "rules: []\n")
	if got := semgrepConfig(r.Root); got != ".semgrep.yml" {
		t.Errorf("got %q", got)
	}
}

func TestOdinCollectionsReadOlsJSON(t *testing.T) {
	dir := t.TempDir()
	if got := odinCollections(dir); got != nil {
		t.Errorf("no ols.json: %v", got)
	}
	if err := os.WriteFile(filepath.Join(dir, "ols.json"), []byte(`{"collections":[{"name":"jfm","path":"../odin"},{"name":"abs","path":"/opt/abs"},{"name":""}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := odinCollections(dir)
	want := []string{"-collection:jfm=" + filepath.Join(dir, "../odin"), "-collection:abs=/opt/abs"}
	if !slices.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}
