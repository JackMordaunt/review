package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// capture collects what is printed to standard output, which is how the
// command reports.
func capture(t *testing.T, fn func()) string {
	t.Helper()
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = write
	done := make(chan string)
	go func() {
		out, _ := io.ReadAll(read)
		done <- string(out)
	}()
	fn()
	write.Close()
	os.Stdout = stdout
	return <-done
}

func TestFilterDropsWhatTheSourceDismisses(t *testing.T) {
	root := t.TempDir()
	source := "package x\n\n//review:ignore restates-a-fact the ico package owns it\nconst b = 6\n"
	if err := os.WriteFile(filepath.Join(root, "x.go"), []byte(source), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(t.TempDir()) // Somewhere else, so that filter has to change directory itself.

	kept, dismissed := filter(root, []Finding{
		{File: "x.go", Line: 4, Rule: "restates-a-fact", Message: "dismissed"},
		{File: "x.go", Line: 4, Rule: "already-named", Message: "kept"},
	})
	if len(dismissed) != 1 {
		t.Fatalf("dismissed %v, want one", dismissed)
	}
	if dismissed[0].Why != "the ico package owns it" {
		t.Errorf("the reason is kept, got %q", dismissed[0].Why)
	}
	if len(kept) != 1 || kept[0].Message != "kept" {
		t.Errorf("kept %v", kept)
	}
}

// A dismissal reaches a few lines either side of itself, so which findings
// it answered has to be readable rather than only countable.
func TestRenderNamesWhatWasDismissed(t *testing.T) {
	dismissed := []Dismissed{{
		Finding: Finding{File: "x.go", Line: 7, Rule: "restates-a-fact"},
		Why:     "the ico package owns it",
	}}
	out := capture(t, func() { render(contract{Dismissed: dismissed}, nil, true) })
	for _, want := range []string{"dismissed: x.go:7", "restates-a-fact", "the ico package owns it"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q missing from:\n%s", want, out)
		}
	}
	// Without being asked, only the count.
	quiet := capture(t, func() { render(contract{Dismissed: dismissed}, nil, false) })
	if strings.Contains(quiet, "the ico package owns it") {
		t.Errorf("got %q", quiet)
	}
}

func TestFilterKeepsEverythingWhenTheRootIsGone(t *testing.T) {
	findings := []Finding{{File: "x.go", Line: 1, Rule: "a"}}
	kept, dismissed := filter(filepath.Join(t.TempDir(), "nowhere"), findings)
	if len(kept) != 1 || len(dismissed) != 0 {
		t.Errorf("got %v, %v", kept, dismissed)
	}
}

func TestReport(t *testing.T) {
	out := capture(t, func() {
		if err := report(contract{Findings: []Finding{{
			Job: "tests", Rule: "cannot-fail", Severity: MustFix,
			File: "x_test.go", Line: 4, Message: "m", Fix: "f",
		}}}); err != nil {
			t.Error(err)
		}
	})
	var envelope struct {
		Findings []struct {
			Rule     string `json:"rule"`
			Severity string `json:"severity"`
			Line     int    `json:"line"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(out), &envelope); err != nil {
		t.Fatalf("%v in:\n%s", err, out)
	}
	if len(envelope.Findings) != 1 {
		t.Fatalf("got %v", envelope.Findings)
	}
	// The severity travels as its name, since the number means nothing to a
	// program reading this.
	if envelope.Findings[0].Severity != "must-fix" || envelope.Findings[0].Line != 4 {
		t.Errorf("got %+v", envelope.Findings[0])
	}
}

// An agent reading the JSON needs an empty list rather than null.
func TestReportNothing(t *testing.T) {
	out := capture(t, func() {
		if err := report(contract{}); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(out, `"findings": []`) {
		t.Errorf("got %s", out)
	}
}

// The contract is what makes an empty findings list readable: the status,
// the parts of the measurement that went missing, and the cost, all in one
// object, with every finding named and marked.
func TestReportCarriesTheContract(t *testing.T) {
	out := capture(t, func() {
		if err := report(contract{
			Version:  contractVersion,
			Status:   "incomplete",
			Provider: "api/probe",
			Retracted: []Retracted{{
				Finding: Finding{Job: "tests", Rule: "cannot-fail", Severity: MustFix, File: "x_test.go", Message: "m"},
				Reason:  "the test can fail",
			}},
			Failed:    []JobFault{{Job: "duplication", Error: "context canceled"}},
			Skipped:   []string{"hygiene"},
			Uncovered: []Gap{{File: "a.odin", Reason: "no tests parser"}},
			Dismissed: []Dismissed{{Finding: Finding{Rule: "cannot-fail"}, Why: "wrong"}},
			Truncated: true,
			Usage:     metered{In: 10, Out: 2, Cached: 1, Replayed: 3, Cost: 0.5},
		}); err != nil {
			t.Error(err)
		}
	})
	var env struct {
		Version   int    `json:"version"`
		Status    string `json:"status"`
		Provider  string `json:"provider"`
		Findings  []any  `json:"findings"`
		Retracted []struct {
			Finding struct {
				ID       string `json:"id"`
				Verified bool   `json:"verified"`
				Severity string `json:"severity"`
			} `json:"finding"`
			Reason string `json:"reason"`
		} `json:"retracted"`
		Failed []struct {
			Job   string `json:"job"`
			Error string `json:"error"`
		} `json:"failed"`
		Skipped   []string `json:"skipped"`
		Uncovered []struct {
			File   string `json:"file"`
			Reason string `json:"reason"`
		} `json:"uncovered"`
		Dismissed []struct {
			Why string `json:"why"`
		} `json:"dismissed"`
		Truncated bool `json:"truncated"`
		Usage     struct {
			In       int     `json:"in"`
			Out      int     `json:"out"`
			Cached   int     `json:"cached"`
			Replayed int     `json:"replayed"`
			Cost     float64 `json:"usd"`
		} `json:"usage"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatalf("%v in:\n%s", err, out)
	}
	if env.Version != contractVersion || env.Status != "incomplete" || env.Provider != "api/probe" {
		t.Errorf("got %d %q %q", env.Version, env.Status, env.Provider)
	}
	if len(env.Retracted) != 1 || env.Retracted[0].Reason != "the test can fail" {
		t.Errorf("got %+v", env.Retracted)
	}
	if env.Retracted[0].Finding.ID == "" || env.Retracted[0].Finding.Verified {
		t.Errorf("a retracted finding is named and unverified, got %+v", env.Retracted[0].Finding)
	}
	if env.Retracted[0].Finding.Severity != "must-fix" {
		t.Errorf("got %q", env.Retracted[0].Finding.Severity)
	}
	if len(env.Failed) != 1 || env.Failed[0].Job != "duplication" || env.Failed[0].Error != "context canceled" {
		t.Errorf("got %+v", env.Failed)
	}
	if len(env.Skipped) != 1 || env.Skipped[0] != "hygiene" {
		t.Errorf("got %+v", env.Skipped)
	}
	if len(env.Uncovered) != 1 || env.Uncovered[0].File != "a.odin" {
		t.Errorf("got %+v", env.Uncovered)
	}
	if len(env.Dismissed) != 1 || env.Dismissed[0].Why != "wrong" {
		t.Errorf("got %+v", env.Dismissed)
	}
	if !env.Truncated || env.Usage.In != 10 || env.Usage.Replayed != 3 || env.Usage.Cost != 0.5 {
		t.Errorf("got %v %+v", env.Truncated, env.Usage)
	}
	if len(env.Findings) != 0 {
		t.Errorf("got %+v", env.Findings)
	}
}

// The status is what keeps an empty findings list from being read as a
// pass when part of the measurement is missing.
func TestStatusOfTheMeasurement(t *testing.T) {
	cases := []struct {
		change *Change
		run    RunResult
		want   string
	}{
		{&Change{}, RunResult{}, "complete"},
		{&Change{Truncated: true}, RunResult{}, "incomplete"},
		{&Change{Uncovered: []Gap{{File: "a.odin", Reason: "no tests parser"}}}, RunResult{}, "incomplete"},
		{&Change{}, RunResult{Failures: []error{fmt.Errorf("tests: context canceled")}}, "incomplete"},
	}
	for _, test := range cases {
		if got := statusOf(test.change, test.run); got != test.want {
			t.Errorf("got %q, want %q", got, test.want)
		}
	}
}

// A retraction is worth reading in full under verbose, because it is the
// second reading's word against the first's.
func TestRenderNamesWhatWasRetracted(t *testing.T) {
	env := contract{Retracted: []Retracted{{
		Finding: Finding{Rule: "cannot-fail", File: "x_test.go", Line: 4},
		Reason:  "the test can fail",
	}}}
	out := capture(t, func() { render(env, nil, true) })
	for _, want := range []string{"retracted: [cannot-fail] x_test.go:4", "the test can fail"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q missing from:\n%s", want, out)
		}
	}
	// The count is said even without being asked.
	quiet := capture(t, func() { render(env, nil, false) })
	if !strings.Contains(quiet, "1 of the findings reported did not survive verification") {
		t.Errorf("got %q", quiet)
	}
}

func TestRenderGroupsBySeverity(t *testing.T) {
	out := capture(t, func() {
		render(contract{
			Findings: []Finding{
				{Job: "tests", Rule: "cannot-fail", Severity: MustFix, File: "a_test.go", Line: 4, Message: "one"},
				{Job: "namer", Rule: "abbreviation", Severity: Note, Symbol: "cfg", Message: "two"},
			},
			Dismissed: []Dismissed{{}, {}},
		}, nil, false)
	})
	for _, want := range []string{"MUST-FIX", "NOTE", "one", "two", "2 findings", "2 dismissed in the source"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q missing from:\n%s", want, out)
		}
	}
	if strings.Count(out, "MUST-FIX") != 1 {
		t.Errorf("a severity is announced once:\n%s", out)
	}
}

func TestRenderNothing(t *testing.T) {
	out := capture(t, func() { render(contract{}, nil, false) })
	if strings.TrimSpace(out) != "no findings" {
		t.Errorf("got %q", out)
	}
	// A silent dismissal is still visible.
	out = capture(t, func() { render(contract{Dismissed: []Dismissed{{}, {}, {}}}, nil, false) })
	if !strings.Contains(out, "3 dismissed in the source") {
		t.Errorf("got %q", out)
	}
}

func TestRepository(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	t.Chdir(r.Root)

	root, err := repository()
	if err != nil {
		t.Fatal(err)
	}
	// A temporary directory may be reached through a symlink, so compare
	// what the filesystem resolves to.
	want, err := filepath.EvalSymlinks(r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := filepath.EvalSymlinks(root); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestRepositoryOutsideOne(t *testing.T) {
	t.Chdir(t.TempDir())
	t.Setenv("GIT_CEILING_DIRECTORIES", os.TempDir())
	if _, err := repository(); err == nil {
		t.Skip("the temporary directory is inside a repository on this machine")
	}
}

func TestIndent(t *testing.T) {
	if got := indent("a\n      b"); got != "a\n    b" {
		t.Errorf("got %q", got)
	}
}

// A commit-msg hook is given a file full of git's own commentary; only the
// author's lines are the message.
func TestReadMessage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "COMMIT_EDITMSG")
	if err := os.WriteFile(path, []byte("review: measure it\n\nBecause.\n# Please enter the commit message\n#\n# On branch main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := readMessage(path)
	if err != nil || got != "review: measure it\n\nBecause." {
		t.Errorf("got %q, %v", got, err)
	}
	if _, err := readMessage(filepath.Join(t.TempDir(), "nowhere")); err == nil {
		t.Error("a missing file was read")
	}
}

// A dismissed finding is named like the rest, so a loop can read back which
// finding the source answered.
func TestReportNamesDismissedFindings(t *testing.T) {
	out := capture(t, func() {
		if err := report(contract{
			Version: contractVersion, Status: "complete",
			Dismissed: []Dismissed{{Finding: Finding{Job: "static", Rule: "no-stutter", File: "x.go", Severity: Consider}, Why: "on purpose"}},
		}); err != nil {
			t.Error(err)
		}
	})
	var env struct {
		Dismissed []struct {
			Finding struct {
				ID       string `json:"id"`
				Severity string `json:"severity"`
			} `json:"finding"`
		} `json:"dismissed"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatal(err)
	}
	if len(env.Dismissed) != 1 || env.Dismissed[0].Finding.ID == "" || env.Dismissed[0].Finding.Severity != "consider" {
		t.Errorf("got %+v", env.Dismissed)
	}
}

func TestMustFix(t *testing.T) {
	if mustFix([]Finding{{Severity: Consider}, {Severity: Note}}) {
		t.Error("consider and note are not refusals")
	}
	if !mustFix([]Finding{{Severity: Note}, {Severity: MustFix}}) {
		t.Error("a must-fix finding is")
	}
}
