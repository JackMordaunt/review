package main

import (
	"os/exec"
	"testing"
)

// The staticcheck tests hold the check against the analyser itself, an
// external authority: when it is absent they fail, they do not skip.
func needStaticcheck(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("staticcheck"); err != nil {
		t.Fatalf("staticcheck is not installed: %v", err)
	}
}

// goModule is the smallest module a fixture needs.
const goModule = "module probe\n\ngo 1.27.0\n"

// withFault is a file staticcheck faults at line 4: a comparison with the
// bool constant it can be simplified past.
const withFault = "package probe\n\nfunc F(x bool) int {\n\tif x == true {\n\t\treturn 1\n\t}\n\treturn 2\n}\n"

func TestStaticcheckReadsTheChange(t *testing.T) {
	needStaticcheck(t)
	r := newRepo(t)
	r.write("go.mod", goModule)
	r.write("a.go", withFault)
	r.stage("go.mod", "a.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := checkStaticcheck(r.Root, "", change)
	if len(findings) != 1 {
		t.Fatalf("got %v, want the simplification finding", findings)
	}
	f := findings[0]
	if f.Rule != "staticcheck/S1002" || f.File != "a.go" || f.Line != 4 {
		t.Errorf("got %s at %s:%d", f.Rule, f.File, f.Line)
	}
	if f.Severity != Consider {
		t.Errorf("severity %s, want consider", f.Severity)
	}
	if f.Job != "static" || f.Message == "" {
		t.Errorf("job %q message %q", f.Job, f.Message)
	}
}

func TestStaticcheckKeepsToTheChange(t *testing.T) {
	needStaticcheck(t)
	r := newRepo(t)
	r.write("go.mod", goModule)
	r.write("a.go", withFault)
	r.commit("a: carry the fault history already holds", "go.mod", "a.go")
	r.write("b.go", "package probe\n\nfunc G() int { return 3 }\n")
	r.stage("b.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	// The fault in a.go is history's, not this change's; the analyser sees
	// it and the check must say nothing about it.
	if findings := checkStaticcheck(r.Root, "", change); len(findings) != 0 {
		t.Fatalf("got %v, want nothing: the fault is not on a line the change adds", findings)
	}
}

func TestStaticcheckReadsARange(t *testing.T) {
	needStaticcheck(t)
	r := newRepo(t)
	r.write("go.mod", goModule)
	r.write("a.go", "package probe\n\nfunc A() int { return 1 }\n")
	r.commit("a: begin", "go.mod", "a.go")
	r.write("b.go", withFault)
	r.commit("b: add the fault", "b.go")
	change, err := Gather("HEAD^..HEAD", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	// A range's tree is not the working tree: the analysis has to run on
	// the tree the change arrived at.
	findings := checkStaticcheck(r.Root, "HEAD^..HEAD", change)
	if len(findings) != 1 {
		t.Fatalf("got %v, want the simplification finding", findings)
	}
	if f := findings[0]; f.File != "b.go" || f.Line != 4 || f.Rule != "staticcheck/S1002" {
		t.Errorf("got %s at %s:%d", f.Rule, f.File, f.Line)
	}
}

func TestStaticcheckSkipsWithoutGoModule(t *testing.T) {
	r := newRepo(t)
	r.write("a.go", "package probe\n")
	r.stage("a.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	var findings []Finding
	out := captureStderr(t, func() {
		findings = checkStaticcheck(r.Root, "", change)
	})
	if len(findings) != 0 {
		t.Fatalf("got %v, want nothing without a go.mod", findings)
	}
	if want := "skipping staticcheck: no go.mod at the repository root\n"; out != want {
		t.Errorf("stderr %q, want %q", out, want)
	}
}

func TestStaticcheckSilentWithoutTheBinary(t *testing.T) {
	r := newRepo(t)
	r.write("go.mod", goModule)
	r.write("a.go", withFault)
	r.stage("go.mod", "a.go")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	// The path goes once the change is gathered: only the check is meant to
	// look for the binary and find it gone.
	t.Setenv("PATH", "")
	if findings := checkStaticcheck(r.Root, "", change); len(findings) != 0 {
		t.Fatalf("got %v, want nothing without the binary", findings)
	}
}

func TestStaticcheckSeverity(t *testing.T) {
	for code, want := range map[string]Severity{
		"SA4006": MustFix,
		"S1002":  Consider,
		"U1000":  Consider,
		"ST1005": Note,
		"QF1003": Note,
	} {
		if got := staticcheckSeverity(code); got != want {
			t.Errorf("%s is %s, want %s", code, got, want)
		}
	}
}
