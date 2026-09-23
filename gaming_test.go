package main

// The anti-gaming checks hold the review to itself: a change that dismisses
// what the reading found, or deletes the tests that would have failed, is
// measured rather than waved through. Nothing here asks a provider, so
// nothing here can be talked around.

import (
	"strings"
	"testing"
)

func TestDiffSidesReadsBothSides(t *testing.T) {
	diff := `--- a/x_test.go
+++ b/x_test.go
@@ -1,4 +1,4 @@
 package x
-func TestA() {}
+func TestB() {}
 func f() {}
`
	added, removed := diffSides(diff)
	if len(added["x_test.go"]) != 1 || added["x_test.go"][0].Line != 2 || added["x_test.go"][0].Text != "func TestB() {}" {
		t.Errorf("added %+v", added)
	}
	if len(removed["x_test.go"]) != 1 || removed["x_test.go"][0] != "func TestA() {}" {
		t.Errorf("removed %+v", removed)
	}
}

// A removed line of content that begins like a header is content, not a
// header: the headers are read where they sit between hunks.
func TestDiffSidesKeepsContentAndHeadersApart(t *testing.T) {
	diff := `--- a/notes.txt
+++ b/notes.txt
@@ -1,2 +1,3 @@
 text
-+++ a/other.txt
+--- b/other.txt
 more
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
---- b/other.txt
-more
`
	added, removed := diffSides(diff)
	if len(added["notes.txt"]) != 1 || added["notes.txt"][0].Line != 2 || added["notes.txt"][0].Text != "--- b/other.txt" {
		t.Errorf("added %+v", added)
	}
	if len(removed["notes.txt"]) != 1 || removed["notes.txt"][0] != "+++ a/other.txt" {
		t.Errorf("removed %+v", removed)
	}
	if len(removed["gone.txt"]) != 2 || removed["gone.txt"][0] != "--- b/other.txt" {
		t.Errorf("removed %+v", removed)
	}
}

func TestSuppressionAdded(t *testing.T) {
	// The ignore comment is assembled at runtime so this file does not add
	// a dismissal of its own — the check reads added lines, and this test's
	// source is an added line of itself.
	diff := `--- a/ico.go
+++ b/ico.go
@@ -1,3 +1,5 @@
 package ico
+//` + `review:ignore cannot-fail the test can fail
+//review:ignore <rule> <why>
 func f() {}
`
	findings := checkSuppressionAdded(&Change{Diff: diff})
	if len(findings) != 1 {
		t.Fatalf("got %+v", findings)
	}
	f := findings[0]
	if f.Rule != "suppression-added" || f.Severity != MustFix || f.Job != "static" {
		t.Errorf("got %+v", f)
	}
	if !strings.Contains(f.Message, "ico.go:2 (cannot-fail)") {
		t.Errorf("got %q", f.Message)
	}
	// A placeholder in the prose that documents the mechanism is not a
	// suppression being added.
	if strings.Contains(f.Message, "<rule>") {
		t.Errorf("counted a documented placeholder: %q", f.Message)
	}
	// The check polices the ignoring, so it cannot be ignored in turn.
	if f.File != "" {
		t.Errorf("got file %q", f.File)
	}
	if _, ok := Suppressed(f); ok {
		t.Error("a suppression-added finding dismissed itself")
	}
}

// A dismissal can only be written where a dismissal works; the prose that
// documents the mechanism is not one.
func TestSuppressionSkipsProse(t *testing.T) {
	diff := `--- a/readme.md
+++ b/readme.md
@@ -1,3 +1,4 @@
 # review
+` + "`//review:ignore <rule> <why>`" + `
 done
`
	if findings := checkSuppressionAdded(&Change{Diff: diff}); len(findings) != 0 {
		t.Fatalf("got %+v", findings)
	}
	// The zero means nothing unless the check still finds a real one: the
	// same comment in a file the readers read is a suppression.
	live := `--- a/ico.go
+++ b/ico.go
@@ -1,2 +1,3 @@
 package ico
+//` + `review:ignore cannot-fail the test can fail
 func f() {}
`
	if findings := checkSuppressionAdded(&Change{Diff: live}); len(findings) != 1 {
		t.Fatalf("got %+v", findings)
	}
}

func TestDeletedTests(t *testing.T) {
	diff := `--- a/ico_test.go
+++ b/ico_test.go
@@ -1,5 +1,4 @@
 package ico
-func TestAssemble(t *testing.T) {}
-func TestWrite(t *testing.T) {}
+func TestAssembleIcons(t *testing.T) {}
 func f() {}
`
	findings := checkDeletedTests(&Change{Diff: diff})
	if len(findings) != 1 {
		t.Fatalf("got %+v", findings)
	}
	f := findings[0]
	if f.Rule != "test-deleted" || f.Severity != MustFix || f.Job != "static" {
		t.Errorf("got %+v", f)
	}
	if f.File != "ico_test.go" {
		t.Errorf("got file %q", f.File)
	}
	if !strings.Contains(f.Message, "TestWrite") {
		t.Errorf("the deleted test is not named: %q", f.Message)
	}
	if strings.Contains(f.Message, "TestAssemble") {
		t.Errorf("the rename was counted as a deletion: %q", f.Message)
	}
	if !strings.Contains(f.Fix, "test-deleted") {
		t.Errorf("the fix does not say how to answer it: %q", f.Fix)
	}
	// A deleted test is the reviewer's decision, so the finding is
	// dismissible where a reader can read it.
	if _, ok := Suppressed(f); ok {
		t.Error("a test-deleted finding dismissed nothing")
	}
}

func TestDeletedJSTests(t *testing.T) {
	diff := `--- a/web/app.test.ts
+++ b/web/app.test.ts
@@ -1,4 +1 @@
 import { it } from "testing";
-it.skip("parses icons", () => {});
-describe("loads", () => {});
+export {};
`
	findings := checkDeletedTests(&Change{Diff: diff})
	if len(findings) != 1 {
		t.Fatalf("got %+v", findings)
	}
	for _, want := range []string{"parses icons", "loads"} {
		if !strings.Contains(findings[0].Message, want) {
			t.Errorf("%q missing from %q", want, findings[0].Message)
		}
	}
}

// A test in a file the runners do not read is not a test going missing;
// it is a function that stopped existing, which is somebody else's subject.
func TestDeletedFunctionsOutsideTestsAreNotTests(t *testing.T) {
	diff := `--- a/ico.go
+++ b/ico.go
@@ -1,3 +1,2 @@
 package ico
-func TestWrite(w io.Writer) {}
-func helper() {}
+func helper() {}
`
	if findings := checkDeletedTests(&Change{Diff: diff}); len(findings) != 0 {
		t.Fatalf("got %+v", findings)
	}
	// The zero means nothing unless the same shape inside a test file is
	// still heard: the same deletion there is a test going missing.
	inTests := `--- a/ico_test.go
+++ b/ico_test.go
@@ -1,3 +1,2 @@
 package ico
-func TestWrite(t *testing.T) {}
-func helper() {}
+func helper() {}
`
	if findings := checkDeletedTests(&Change{Diff: inTests}); len(findings) != 1 {
		t.Fatalf("got %+v", findings)
	}
}

func TestCoveredSparesARename(t *testing.T) {
	if !covered("TestParseIcons", []string{"TestParseIconsV2", "TestWrite"}) {
		t.Error("a rename was read as a deletion")
	}
	if covered("TestParseIcons", []string{"TestParse", "TestWrite"}) {
		t.Error("a different test was read as the same one")
	}
	// A name with no words of its own cannot be matched safely, so it is
	// never spared.
	if covered("TestV2", []string{"TestV2"}) {
		t.Error("covered a name it cannot read")
	}
}

func TestFilePredicates(t *testing.T) {
	for _, path := range []string{"ico.go", "web/app.ts", "main.rs", "makefile"} {
		if !isCodeFile(path) {
			t.Errorf("isCodeFile(%q) = false", path)
		}
	}
	for _, path := range []string{"readme.md", ".gitignore", "LICENSE"} {
		if isCodeFile(path) {
			t.Errorf("isCodeFile(%q) = true", path)
		}
	}
	for _, path := range []string{"ico_test.go", "web/app.test.ts", "web/app.spec.js"} {
		if !isTestFile(path) {
			t.Errorf("isTestFile(%q) = false", path)
		}
	}
	for _, path := range []string{"ico.go", "web/app.ts"} {
		if isTestFile(path) {
			t.Errorf("isTestFile(%q) = true", path)
		}
	}
}

func TestRemovedTestNameReadsEveryRunner(t *testing.T) {
	for line, want := range map[string]string{
		`Deno.test("deno string", () => {`:           "deno string",
		`Deno.test.ignore("deno ignored", () => {`:   "deno ignored",
		`  test.skip("bun skipped", () => {`:         "bun skipped",
		`it.only("focused", () => {`:                 "focused",
		`test('node plain', { timeout: 5 }, () => {`: "node plain",
		`test.concurrent.only("both", async () => {`: "both",
		`describe("suite", () => {`:                  "suite",
		`Deno.test({ name: "object", fn() {`:         "",
		`const test = 1;`:                            "",
	} {
		if got := removedTestName(line); got != want {
			t.Errorf("%q: got %q, want %q", line, got, want)
		}
	}
}
