package main

// The loop an agent runs is: review, fix, review again. What it needs from
// the second run is which findings went away, which stayed, and which are
// new; what it needs from every finding is enough to act without opening
// the file.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCompareNamesFindingsAgainstABaseline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "before.json")
	before := `{"findings":[{"id":"aaa"},{"id":"bbb"}],"retracted":[{"finding":{"id":"zzz"}}]}`
	if err := os.WriteFile(path, []byte(before), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := compare(path, []Finding{{ID: "bbb"}, {ID: "ccc"}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got.Resolved, ",") != "aaa" || strings.Join(got.Persisting, ",") != "bbb" || strings.Join(got.New, ",") != "ccc" {
		t.Errorf("got %+v", got)
	}
	// A retracted finding in the baseline was never one to fix.
	for _, id := range got.Resolved {
		if id == "zzz" {
			t.Error("a retracted finding counted as resolved")
		}
	}
	if _, err := compare(filepath.Join(t.TempDir(), "nowhere.json"), nil); err == nil {
		t.Error("a missing baseline was read")
	}
	bad := filepath.Join(t.TempDir(), "bad.json")
	os.WriteFile(bad, []byte("not json"), 0o644)
	if _, err := compare(bad, nil); err == nil {
		t.Error("a baseline that is not a report was read")
	}
}

func TestReportCarriesTheBaseline(t *testing.T) {
	out := capture(t, func() {
		if err := report(contract{Version: contractVersion, Status: "complete",
			Baseline: &Baseline{From: "before.json", Resolved: []string{"aaa"}, Persisting: []string{}, New: []string{}}}); err != nil {
			t.Error(err)
		}
	})
	var env struct {
		Baseline struct {
			From     string   `json:"from"`
			Resolved []string `json:"resolved"`
			New      []string `json:"new"`
		} `json:"baseline"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatal(err)
	}
	if env.Baseline.From != "before.json" || len(env.Baseline.Resolved) != 1 || env.Baseline.New == nil {
		t.Errorf("got %+v", env.Baseline)
	}
	// Without a baseline the key is absent rather than null.
	plain := capture(t, func() { report(contract{Version: contractVersion, Status: "complete"}) })
	if strings.Contains(plain, "baseline") {
		t.Errorf("a report without a baseline mentions one:\n%s", plain)
	}
}

func TestRenderSaysHowFindingsStandAgainstTheBaseline(t *testing.T) {
	out := capture(t, func() {
		render(contract{Baseline: &Baseline{From: "before.json", Resolved: []string{"a"}, Persisting: []string{"b", "c"}}}, nil, false)
	})
	if !strings.Contains(out, "against before.json: 1 resolved, 2 persisting, 0 new") || !strings.Contains(out, "persisting: b, c") {
		t.Errorf("got %q", out)
	}
}

func TestTreeLine(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n\n  var a = 1  \n")
	r.commit("first", "x.go")
	tree, err := treeAt(r.Root, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := tree.Line("x.go", 3); got != "var a = 1" {
		t.Errorf("got %q", got)
	}
	if tree.Line("x.go", 9) != "" || tree.Line("nowhere.go", 1) != "" || tree.Line("x.go", 0) != "" {
		t.Error("a line that is not there was read")
	}
}

// A note is never gated on, so the second reading is not spent on it: the
// finding stands, unverified, and only the other severities are asked about.
func TestVerifySkipsNotes(t *testing.T) {
	provider := &relenting{answers: []string{
		`{"findings":[{"rule":"cannot-fail","severity":"note","file":"x_test.go","line":4,"message":"m","fix":"f"},` +
			`{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":5,"message":"n","fix":"f"}]}`,
		verdictJSON(`{"index":0,"holds":true,"reason":""}`),
	}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Findings) != 2 || len(result.Failures) != 0 {
		t.Fatalf("got %+v", result)
	}
	if !strings.Contains(provider.asked[1], "0. [cannot-fail] must-fix") || strings.Contains(provider.asked[1], "1. [cannot-fail]") {
		t.Errorf("the verdict was asked about the note:\n%s", provider.asked[1])
	}
	for _, f := range result.Findings {
		if (f.Severity == Note) == f.Verified {
			t.Errorf("verified %v for %s", f.Verified, f.Severity)
		}
	}
}

// A subject over the cap is asked in parts, file by file, each part its
// own ask and its own verdict against its own evidence.
func TestOversizedSubjectIsAskedInParts(t *testing.T) {
	change := &Change{Files: []string{"a_test.go", "b_test.go", "c_test.go"}}
	for _, file := range change.Files {
		change.Tests = append(change.Tests, Function{
			Name: "Test" + strings.ToUpper(file[:1]), File: file, Line: 3,
			Body: "func Test(t *testing.T) {\n" + strings.Repeat("\tt.Log(\"padding padding padding padding\")\n", packetCap/80) + "}",
		})
	}
	job, _ := chosen("tests")
	pieces := parts(job[0], change)
	if len(pieces) != 3 {
		t.Fatalf("cut into %d parts, want one per file", len(pieces))
	}
	for i, piece := range pieces {
		if len(piece.Tests) != 1 || piece.Tests[0].File != change.Files[i] {
			t.Errorf("part %d holds %v", i, piece.Tests)
		}
	}
	// One finding from the second part; the verdict is asked against that
	// part alone.
	provider := &relenting{answers: []string{
		`{"findings":[]}`,
		findingsJSON("cannot-fail"),
		`{"findings":[]}`,
		verdictJSON(`{"index":0,"holds":true,"reason":""}`),
	}}
	t.Setenv("REVIEW_SERIAL", "1")
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), change, job)
	if len(result.Findings) != 1 || !result.Findings[0].Verified || len(result.Failures) != 0 {
		t.Fatalf("got %+v", result)
	}
	if len(provider.asked) != 4 {
		t.Fatalf("asked %d times, want three parts and one verdict", len(provider.asked))
	}
	if !strings.Contains(provider.asked[3], "b_test.go") || strings.Contains(provider.asked[3], "a_test.go") {
		t.Errorf("the verdict was not asked against the part the finding came from:\n%s", first(provider.asked[3], 300))
	}
}

func TestSmallSubjectIsNotSplit(t *testing.T) {
	change := verifyChange()
	change.Files = []string{"x_test.go"}
	job, _ := chosen("tests")
	if pieces := parts(job[0], change); len(pieces) != 1 || pieces[0] != change {
		t.Errorf("a small subject was cut: %d parts", len(pieces))
	}
	hygiene, _ := chosen("hygiene")
	if pieces := parts(hygiene[0], &Change{Message: strings.Repeat("word ", packetCap)}); len(pieces) != 1 {
		t.Error("an unsplittable job was cut")
	}
}
