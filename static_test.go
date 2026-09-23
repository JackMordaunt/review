package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The checks are pure over the message, so they are tested directly; the
// Gathered shape of a message is tested where it is gathered.

func TestLowEntropyIsReported(t *testing.T) {
	change := &Change{Message: strings.Repeat("asdf asdf ", 6)}
	findings := runChecks(change)
	if len(findings) != 1 {
		t.Fatalf("got %d findings, want one:\n%v", len(findings), findings)
	}
	f := findings[0]
	if f.Job != "static" || f.Rule != "message-low-entropy" || f.Severity != MustFix {
		t.Errorf("got %s/%s/%s", f.Job, f.Rule, f.Severity)
	}
	// A failure explains itself: the measurement, the threshold, and why a
	// message can measure that low.
	for _, want := range []string{"2.3", "Shannon", "3.2", "phrase repeated"} {
		if !strings.Contains(f.Message, want) {
			t.Errorf("%q missing from: %s", want, f.Message)
		}
	}
}

func TestBoilerplateIsReported(t *testing.T) {
	change := &Change{Message: strings.Repeat(licenceLine, 9)}
	findings := runChecks(change)
	if len(findings) != 1 {
		t.Fatalf("got %d findings, want one:\n%v", len(findings), findings)
	}
	f := findings[0]
	if f.Rule != "message-boilerplate" {
		t.Errorf("got %s", f.Rule)
	}
	for _, want := range []string{"compresses", "20%", "pasted"} {
		if !strings.Contains(f.Message, want) {
			t.Errorf("%q missing from: %s", want, f.Message)
		}
	}
}

// A message can fail both at once, and each check answers for itself.
func TestBothChecksFireOnOneMessage(t *testing.T) {
	change := &Change{Message: strings.Repeat("asdf asdf asdf asdf asdf asdf\n", 20)}
	var got []string
	for _, f := range runChecks(change) {
		got = append(got, f.Rule)
	}
	if len(got) != 2 || got[0] == got[1] {
		t.Errorf("got %v, want both rules once each", got)
	}
}

func TestChecksStaySilentOnAMessageThatSaysSomething(t *testing.T) {
	change := &Change{Message: goodMessage}
	if findings := runChecks(change); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// Below the floors a measurement says nothing either way: a short subject is
// low-entropy whatever it says, and zlib cannot beat its own framing.
func TestShortMessagesAreNotMeasured(t *testing.T) {
	for _, msg := range []string{"wip", strings.Repeat(licenceLine, 4)} {
		if findings := runChecks(&Change{Message: msg}); len(findings) != 0 {
			t.Errorf("%q: got %v", msg, findings)
		}
	}
}

// A staged change has no message of its own, so nothing measures one: the
// previous commit's message described other work, and a finding about it
// would send the author to fix a commit the change did not make.
func TestStagedChangeMeasuresNoMessage(t *testing.T) {
	r := newRepo(t)
	r.write("seed.txt", "seed\n")
	r.commit(strings.Repeat("asdf asdf ", 6), "seed.txt")
	parts := []string{"package x\n\n"}
	for i := 0; i < 60; i++ {
		parts = append(parts, fmt.Sprintf("var v%d = %d\n", i, i))
	}
	r.write("x.go", strings.Join(parts, ""))
	r.stage("x.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if change.Message != "" {
		t.Fatalf("a staged change carries a message: %q", change.Message)
	}
	for _, f := range runChecks(change) {
		if strings.HasPrefix(f.Rule, "message-") {
			t.Errorf("measured a message that does not exist: %v", f)
		}
	}
}

// The checks read what Gather read, including a message git itself produced.
func TestStaticAgainstARealCommit(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	r.write("y.go", "package x\n")
	r.commit(strings.Repeat("asdf asdf ", 6), "y.go")

	change, err := Gather("HEAD^", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := runChecks(change)
	if len(findings) != 1 || findings[0].Rule != "message-low-entropy" {
		t.Errorf("got %v", findings)
	}
}

func TestStaticAgainstALicensedCommitMessage(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit(strings.Repeat(licenceLine, 9), "x.go")

	change, err := Gather("HEAD", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := runChecks(change)
	if len(findings) != 1 || findings[0].Rule != "message-boilerplate" {
		t.Errorf("got %v", findings)
	}
}

// commonHistory is a history in which fix and build are common and nothing
// else is: enough subjects, said over and over, for the frequencies to mean
// something.
func commonHistory() []string {
	var h []string
	for i := 0; i < 60; i++ {
		h = append(h, "fix the failing build", "build: fix the build", "fix build")
	}
	return h
}

func TestCommonWordsAreReported(t *testing.T) {
	change := &Change{
		Message: "fix build",
		History: commonHistory(),
		Files:   []string{"auth_service.go"},
		Diff:    "+type JWTParser struct{}\n",
	}
	findings := runChecks(change)
	if len(findings) != 1 {
		t.Fatalf("got %d findings, want one:\n%v", len(findings), findings)
	}
	f := findings[0]
	if f.Rule != "message-common-words" {
		t.Errorf("got %s", f.Rule)
	}
	for _, want := range []string{"fix", "build", "180", "names nothing"} {
		if !strings.Contains(f.Message, want) {
			t.Errorf("%q missing from: %s", want, f.Message)
		}
	}
}

// One word the history has never used is enough to spare a message: a
// message like this cannot have written that word without reading the
// change.
func TestAWordTheHistoryHasNotUsedIsSilent(t *testing.T) {
	change := &Change{
		Message: "fix the parser deadlock",
		History: commonHistory(),
		Files:   []string{"auth_service.go"},
	}
	if findings := runChecks(change); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// Naming what the change touches spares a message even when every word is
// common: Update requests.ts is not updated the thing.
func TestNamingTheChangeIsSilent(t *testing.T) {
	history := commonHistory()
	for i := 0; i < 40; i++ {
		history = append(history, "update the parser", "parser: update")
	}
	change := &Change{
		Message: "update parser",
		History: history,
		Files:   []string{"parser.go"},
		Diff:    "+func Parse() {}\n",
	}
	if findings := runChecks(change); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// A version or an issue number is information however few words carry it.
func TestVersionNumberSparesAMessage(t *testing.T) {
	history := commonHistory()
	for i := 0; i < 40; i++ {
		history = append(history, "bump version")
	}
	change := &Change{
		Message: "bump to 2.0.26",
		History: history,
		Files:   []string{"version.go"},
	}
	if findings := runChecks(change); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// Below a hundred subjects the frequencies are too thin to judge by, and a
// repository that young has not earned the accusation.
func TestThinHistoryIsSilent(t *testing.T) {
	change := &Change{
		Message: "fix build",
		History: commonHistory()[:99],
		Files:   []string{"auth_service.go"},
	}
	if findings := runChecks(change); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// Merge and squash subjects are git's words, not the commit's.
func TestMergeMessagesAreSilent(t *testing.T) {
	for _, msg := range []string{
		"Merge branch 'main' into dev",
		"Squashed 'vendor/x/' content from branch main",
	} {
		change := &Change{Message: msg, History: commonHistory()}
		if findings := runChecks(change); len(findings) != 0 {
			t.Errorf("%q: got %v", msg, findings)
		}
	}
}

func TestVentingIsReported(t *testing.T) {
	for _, msg := range []string{
		"whoops",
		"oops, missed a comma",
		"damn, ran the formatter with spaces instead of tabs",
		"WHOOPS, left the debug print in",
	} {
		findings := runChecks(&Change{Message: msg})
		if len(findings) != 1 || findings[0].Rule != "message-frustration" {
			t.Errorf("%q: got %v", msg, findings)
			continue
		}
		if !strings.Contains(findings[0].Message, "exclamation") {
			t.Errorf("%q: %s", msg, findings[0].Message)
		}
	}
}

// Words that history shows describing code legitimately are not markers:
// Odin says stupid UB and implements dumb PtrMap, and finally and
// eventually belong to real prose.
func TestTechnicalWordsAreSilent(t *testing.T) {
	for _, msg := range []string{
		"Change >> behaviour in LLVM to prevent stupid UB",
		"Respect TERM=dumb in the test runner",
		"Implement dumb PtrMap",
		"Temporarily fix the syscall (eventually to be replaced)",
		"finally fixed the flaky resize test",
	} {
		if findings := runChecks(&Change{Message: msg}); len(findings) != 0 {
			t.Errorf("%q: got %v", msg, findings)
		}
	}
}

// A real commit that is only an admission is caught through Gather too.
func TestVentingAgainstARealCommit(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("whoops", "x.go")

	change, err := Gather("HEAD", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := runChecks(change)
	if len(findings) != 1 || findings[0].Rule != "message-frustration" {
		t.Errorf("got %v", findings)
	}
}

func TestMoodIsChecked(t *testing.T) {
	for _, msg := range []string{
		"Added readme.",
		"Fixing the build",
		"This fixes the crash",
		"i can't spell",
		"web: solarized palette at artifact-page contrast",
		"deps: upgraded the webp",
	} {
		findings := runChecks(&Change{Message: msg})
		if len(findings) != 1 || findings[0].Rule != "message-not-imperative" {
			t.Errorf("%q: got %v", msg, findings)
			continue
		}
		if !strings.Contains(findings[0].Message, "imperative mood") {
			t.Errorf("%q: %s", msg, findings[0].Message)
		}
	}
}

// Verbs whose past and imperative share a form are spared, articles are
// spared because an explainer may be a noun phrase on purpose, and the
// suffix rules must not hear speed and feed as past.
func TestMoodIsSpared(t *testing.T) {
	for _, msg := range []string{
		"review: measure the message without a model",
		"icnsify: read icons out of a Windows binary",
		"Add caching for responses",
		"Bump to 2.0.x",
		"review: an eval set, and the criteria tuned against it",
		"docs: the vocabulary, the voices section, and the three providers",
		"Speed up the build",
		"Merge branch 'main' into dev",
		"Squashed 'vendor/x/' content from branch main",
	} {
		if findings := runChecks(&Change{Message: msg}); len(findings) != 0 {
			t.Errorf("%q: got %v", msg, findings)
		}
	}
}

// A past-tense commit in a real history is caught through Gather too.
func TestMoodAgainstARealCommit(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("Added readme.", "x.go")

	change, err := Gather("HEAD", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := runChecks(change)
	if len(findings) != 1 || findings[0].Rule != "message-not-imperative" {
		t.Errorf("got %v", findings)
	}
}

func TestBodyIsOwed(t *testing.T) {
	findings := runChecks(&Change{Message: "feat: add the thing", Diff: strings.Repeat("+line\n", 51)})
	if len(findings) != 1 || findings[0].Rule != "message-no-body" {
		t.Errorf("got %v", findings)
		return
	}
	if !strings.Contains(findings[0].Message, "carries no body") {
		t.Errorf("%s", findings[0].Message)
	}
}

func TestBodyIsSpared(t *testing.T) {
	for _, tt := range []struct {
		diff, subject, body string
	}{
		{strings.Repeat("+line\n", 10), "feat: add the thing", ""},
		{strings.Repeat("+line\n", 500), "feat: add the thing", "one two three four five"},
		{strings.Repeat("+line\n", 500), "feat: add the thing", variedWords(150)},
		{strings.Repeat("+line\n", 500), "Merge branch 'main'", ""},
		// A formatting run: the same lines removed and added in another
		// order, changed not at all.
		{strings.Repeat("+x\n", 30) + strings.Repeat("-x\n", 30), "format: run gofmt", ""},
	} {
		msg := tt.subject
		if tt.body != "" {
			msg += "\n\n" + tt.body
		}
		if findings := runChecks(&Change{Message: msg, Diff: tt.diff}); len(findings) != 0 {
			t.Errorf("%q over %d diff lines: got %v", tt.subject, len(tt.diff)/6, findings)
		}
	}
}

// variedWords are n distinct words, so that a fixture body of a given
// length does not read to the other checks as one phrase repeated.
func variedWords(n int) string {
	words := make([]string, 0, n)
	for i := range n {
		words = append(words, fmt.Sprintf("word%d", i))
	}
	return strings.Join(words, " ")
}

func TestBodyIsCapped(t *testing.T) {
	msg := "feat: add the thing\n\n" + variedWords(151)
	findings := runChecks(&Change{Message: msg, Diff: strings.Repeat("+line\n", 10)})
	if len(findings) != 1 || findings[0].Rule != "message-long-body" {
		t.Errorf("got %v", findings)
	}
	if findings := runChecks(&Change{Message: "feat: add\n\n" + variedWords(150)}); len(findings) != 0 {
		t.Errorf("150 words: got %v", findings)
	}
}

// A large subject-only change is caught through Gather too, with the
// message a commit-msg hook would supply for the staged change.
func TestBodyAgainstARealCommit(t *testing.T) {
	r := newRepo(t)
	r.write("seed.txt", "seed\n")
	r.commit("seed", "seed.txt")

	parts := []string{"package x\n\n"}
	for i := 0; i < 60; i++ {
		parts = append(parts, fmt.Sprintf("var v%d = %d\n", i, i))
	}
	r.write("x.go", strings.Join(parts, ""))
	r.stage("x.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	change.Message = "x: add sixty variables"
	findings := only(runChecks(change), "message-")
	if len(findings) != 1 || findings[0].Rule != "message-no-body" {
		t.Errorf("got %v", findings)
	}
}

// TestTemporalIsReported runs the whole check set over a change whose
// history names an untouched partner, so the finding survives the others.
func TestTemporalIsReported(t *testing.T) {
	findings := runChecks(&Change{
		Files: []string{"login.go"},
		Temporal: &Temporal{
			Commits:  map[string]int{"login.go": 10, "session.go": 9},
			Partners: map[string][]Partner{"login.go": {{Name: "session.go", Shared: 9}}},
		},
	})
	if len(findings) != 1 || findings[0].Rule != "history-coupled-file" {
		t.Errorf("got %v", findings)
		return
	}
	for _, want := range []string{"login.go", "session.go", "9 of the 10"} {
		if !strings.Contains(findings[0].Message, want) {
			t.Errorf("message lacks %q: %s", want, findings[0].Message)
		}
	}
}

func TestTemporalIsSpared(t *testing.T) {
	tests := []struct {
		name     string
		files    []string
		temporal *Temporal
	}{
		{"no history", []string{"a.go"}, nil},
		{"partner touched too", []string{"a.go", "b.go"}, &Temporal{
			Commits:  map[string]int{"a.go": 10, "b.go": 9},
			Partners: map[string][]Partner{"a.go": {{Name: "b.go", Shared: 9}}},
		}},
		{"below the coupling", []string{"a.go"}, &Temporal{
			Commits:  map[string]int{"a.go": 10, "b.go": 10},
			Partners: map[string][]Partner{"a.go": {{Name: "b.go", Shared: 5}}},
		}},
		{"below the support", []string{"a.go"}, &Temporal{
			Commits:  map[string]int{"a.go": 3, "b.go": 3},
			Partners: map[string][]Partner{"a.go": {{Name: "b.go", Shared: 3}}},
		}},
	}
	for _, tt := range tests {
		if findings := checkTemporal(&Change{Files: tt.files, Temporal: tt.temporal}); len(findings) != 0 {
			t.Errorf("%s: got %v", tt.name, findings)
		}
	}
}

// Through Gather, the check counts the history git holds, and a change that
// touches both halves of a coupled pair is left alone.
func TestTemporalAgainstARealCommit(t *testing.T) {
	r := newRepo(t)
	r.write("seed.txt", "seed\n")
	r.commit("seed", "seed.txt")
	for i := 0; i < 8; i++ {
		r.write("a.go", fmt.Sprintf("package a\n\nvar v%d = %d\n", i, i))
		r.write("b.go", fmt.Sprintf("package b\n\nvar w%d = %d\n", i, i))
		r.commit(fmt.Sprintf("grow: the pair, round %d", i), "a.go", "b.go")
	}
	r.write("a.go", "package a\n\nvar v8 = 8\n\nvar v9 = 9\n")
	r.stage("a.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	findings := only(runChecks(change), "history-")
	if len(findings) != 1 || findings[0].Rule != "history-coupled-file" {
		t.Errorf("got %v", findings)
		return
	}
	if findings[0].File != "a.go" || !strings.Contains(findings[0].Message, "b.go") {
		t.Errorf("%s\n%s", findings[0].File, findings[0].Message)
	}

	// The pair touched together is the coupling honoured, and the check
	// says nothing.
	r.write("b.go", "package b\n\nvar w8 = 8\n\nvar w9 = 9\n")
	r.stage("b.go")
	change, err = Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if findings := only(runChecks(change), "history-"); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// A partner the tree no longer holds is history's partner, not the
// change's, and the check says nothing of it.
func TestTemporalSparesAGonePartner(t *testing.T) {
	r := newRepo(t)
	r.write("a.go", "package a\n")
	r.write("b.go", "package b\n")
	for i := 0; i < 8; i++ {
		r.write("a.go", fmt.Sprintf("package a\n\nvar v%d = %d\n", i, i))
		r.write("b.go", fmt.Sprintf("package b\n\nvar w%d = %d\n", i, i))
		r.commit(fmt.Sprintf("grow: the pair, round %d", i), "a.go", "b.go")
	}
	r.write("b.go", "gone")
	r.commit("retire: the partner", "b.go")
	if err := os.Remove(filepath.Join(r.Root, "b.go")); err != nil {
		t.Fatal(err)
	}
	r.write("a.go", "package a\n\nvar v8 = 8\n\nvar v9 = 9\n")
	r.stage("a.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if findings := only(runChecks(change), "history-"); len(findings) != 0 {
		t.Errorf("got %v", findings)
	}
}

// Through Gather, the check reads the history git holds, against the
// message supplied for the staged change.
func TestCommonWordsAgainstARealHistory(t *testing.T) {
	r := newRepo(t)
	for i := 0; i < 110; i++ {
		r.run("commit", "--allow-empty", "-q", "-m", "fix build")
	}
	r.write("auth_service.go", "package auth\n\ntype JWTParser struct{}\n")
	r.stage("auth_service.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	change.Message = "fix build"
	findings := only(runChecks(change), "message-")
	if len(findings) != 1 || findings[0].Rule != "message-common-words" {
		t.Fatalf("got %v", findings)
	}
}

const licenceLine = "Copyright 2026 Example Corp. All rights reserved. Licensed under the Apache License, Version 2.0.\n"

const goodMessage = `review: say which findings the source dismissed

A dismissal answered the finding above it and was then thrown away with
the finding, so a reading that met a third of the change reported less
than it read. Kept beside the finding they answered, a dismissal is
visible where a silent one was not, and --verbose names the reason it
gave rather than leaving a gap in the list for nobody to explain.

The window a dismissal covers stays as written: a few lines either side
of the comment, because narrowing it waits on a case that shows the
narrowing losing a finding it should have kept.`

// The gaming checks are wired into the ordinary run: a change that
// dismisses what the readers would have found, or deletes the tests that
// would have failed, is measured before anything is asked of a provider.
// The ignore comment is assembled at runtime, so this file does not add a
// dismissal of its own while testing the check that counts them.
func TestChecksHoldTheChangeToTheReview(t *testing.T) {
	change := &Change{Diff: `--- a/x_test.go
+++ b/x_test.go
@@ -1,2 +1,2 @@
 package x
+//` + `review:ignore all tidy
-func TestA(t *testing.T) {}
`}
	var got []string
	for _, f := range runChecks(change) {
		if f.Severity != MustFix {
			t.Errorf("%s is %s, want must-fix", f.Rule, f.Severity)
		}
		got = append(got, f.Rule)
	}
	for _, want := range []string{"suppression-added", "test-deleted"} {
		if !slices.Contains(got, want) {
			t.Errorf("%s missing from %v", want, got)
		}
	}
}

// only keeps the findings whose rule opens with the prefix, so a test of
// one check against a real repository is not answered by the others.
func only(findings []Finding, prefix string) []Finding {
	var out []Finding
	for _, f := range findings {
		if strings.HasPrefix(f.Rule, prefix) {
			out = append(out, f)
		}
	}
	return out
}

// A message naming code that is nowhere in the repository describes work
// the diff does not contain.
func TestNamesUnknown(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n\nfunc readConfig() {}\n")
	r.commit("first", "x.go")
	r.write("x.go", "package x\n\nfunc readConfig() {}\n\nfunc parseFlags() {}\n")
	r.write("docs/notes.md", "notes\n")
	r.stage("x.go", "docs/notes.md")
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		message string
		fires   bool
	}{
		{"x: add parseFlags beside readConfig", false},     // both exist
		{"x: add parseConfig()", true},                     // remembered wrong
		{"x: add `load_settings` for docs/notes.md", true}, // backticked, unknown
		{"x: touch docs/notes.md", false},                  // a path in the tree
		{"x: make the reader faster", false},               // no identifier at all
		{"x: see https://example.com/parseConfig", false},  // a link is not a name
	} {
		change.Message = test.message
		got := only(runChecks(change), "message-names-unknown")
		if (len(got) == 1) != test.fires {
			t.Errorf("%q: got %v", test.message, got)
		}
	}
}

func TestBrandShaped(t *testing.T) {
	for word, want := range map[string]bool{
		"gRPC": true, "iOS": true, "macOS": true, "eBay": true, "getID": false, "parseConfig": false, "readURL": false, "id": false,
	} {
		if got := brandShaped(word); got != want {
			t.Errorf("%s: %v, want %v", word, got, want)
		}
	}
}
