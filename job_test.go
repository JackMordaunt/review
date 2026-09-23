package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

func TestRules(t *testing.T) {
	criteria := "# Naming\n\n" +
		"- `noun-for-type` — a type is a noun.\n" +
		"- `verb-for-func` — a function is a verb.\n" +
		"  - `not-a-rule` — indented, so not a rule id.\n" +
		"- not a rule at all\n" +
		"- `Shouty` — capitals are not rule ids.\n"
	got := rules(criteria)
	want := map[string]bool{"noun-for-type": true, "verb-for-func": true}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for id := range want {
		if !got[id] {
			t.Errorf("%s missing from %v", id, got)
		}
	}
}

// Every job's criteria have to define at least one citable id, or the job can
// report nothing that survives filtering.
func TestEveryJobDefinesRules(t *testing.T) {
	for _, job := range Jobs() {
		ids := rules(job.Criteria)
		if len(ids) == 0 {
			t.Errorf("job %q defines no rule ids", job.Name)
		}
		for id := range ids {
			if strings.TrimSpace(id) == "" {
				t.Errorf("job %q defines an empty rule id", job.Name)
			}
		}
	}
}

func TestReportedFindingsDropsAnUnknownRule(t *testing.T) {
	r, err := decode(`{"findings":[
		{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"message":"kept","fix":"f"},
		{"rule":"invented-by-the-model","severity":"must-fix","message":"dropped"},
		{"rule":"","severity":"note","message":"also dropped"}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	got := r.findings("tests", map[string]bool{"cannot-fail": true})
	if len(got) != 1 {
		t.Fatalf("got %d findings, want only the one citing a known rule: %v", len(got), got)
	}
	if got[0].Job != "tests" || got[0].Rule != "cannot-fail" || got[0].Severity != MustFix {
		t.Errorf("got %+v", got[0])
	}
	if got[0].SeverityName != "must-fix" {
		t.Errorf("the severity as reported is kept for JSON, got %q", got[0].SeverityName)
	}
}

func TestDecode(t *testing.T) {
	r, err := decode(`{"findings":[{"rule":"cannot-fail","severity":"note","file":"x.go","line":3,"message":"m","fix":"f"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Findings) != 1 || r.Findings[0].Line != 3 {
		t.Fatalf("got %+v", r.Findings)
	}
	if _, err := decode(`not json`); err == nil {
		t.Error("decoding rubbish should fail")
	}
	// An empty list is how a job reports nothing, and must not be an error.
	if _, err := decode(`{"findings":[]}`); err != nil {
		t.Errorf("an empty report is valid: %v", err)
	}
}

func TestChosen(t *testing.T) {
	all, err := chosen("")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != len(Jobs()) {
		t.Errorf("got %d jobs, want all of them", len(all))
	}
	some, err := chosen("namer, tests")
	if err != nil {
		t.Fatal(err)
	}
	if len(some) != 2 || some[0].Name != "namer" || some[1].Name != "tests" {
		t.Errorf("got %v", some)
	}
	if _, err := chosen("nonsense"); err == nil {
		t.Error("an unknown job should be named as such")
	}
}

// A job with nothing to read renders nothing, which is what keeps a
// documentation-only commit from paying for a test review.
func TestSubjectsAreEmptyWithNothingToRead(t *testing.T) {
	empty := &Change{Candidates: map[string][]string{}}
	for _, job := range Jobs() {
		if got := job.Subject(empty); strings.TrimSpace(got) != "" {
			t.Errorf("job %q renders %q for an empty change", job.Name, got)
		}
	}
}

func TestSubjectsRenderWhatTheirJobReads(t *testing.T) {
	change := &Change{
		Symbols: []Symbol{{
			Name: "Stored", Kind: "type", File: "ico/ico.go", Line: 12,
			Exported: true, Signature: "type Stored struct {", Doc: "Stored is an icon already encoded.",
		}},
		Tests:      []Function{{Name: "TestWrite", File: "ico/w_test.go", Line: 3, Body: "func TestWrite(t *testing.T) {\n\tt.Skip()\n}"}},
		Comments:   []Located{{Text: "Windows rejects a 256 pixel icon.", File: "exe/exe.go", Line: 40}},
		Message:    "ico: assemble a file",
		Stat:       " ico/ico.go | 3 +++",
		Convention: []string{"ico: read a directory", "exe: carry icons"},
		Candidates: map[string][]string{"Stored": {"ico/ico.go:4: type Encoded struct {"}},
	}
	for _, test := range []struct {
		job  string
		want []string
		gone []string
	}{
		{"namer", []string{"Stored", "(exported)", "type Stored struct {", "doc:", "type Encoded struct {"}, []string{"TestWrite", "Windows rejects"}},
		{"duplication", []string{"NEW", "Stored", "candidates:", "type Encoded struct {"}, []string{"TestWrite"}},
		{"tests", []string{"TestWrite", "t.Skip()"}, []string{"Stored"}},
		{"claims", []string{"Windows rejects a 256 pixel icon.", "exe/exe.go:40"}, []string{"TestWrite"}},
		{"hygiene", []string{"ico: assemble a file", "ico/ico.go | 3 +++", "ico: read a directory"}, []string{"TestWrite"}},
	} {
		t.Run(test.job, func(t *testing.T) {
			jobs, err := chosen(test.job)
			if err != nil {
				t.Fatal(err)
			}
			got := jobs[0].Subject(change)
			for _, want := range test.want {
				if !strings.Contains(got, want) {
					t.Errorf("%q missing from:\n%s", want, got)
				}
			}
			for _, gone := range test.gone {
				if strings.Contains(got, gone) {
					t.Errorf("%q leaked into another job's subject:\n%s", gone, got)
				}
			}
		})
	}
}

func TestDuplicationSubjectSaysWhenThereAreNoCandidates(t *testing.T) {
	change := &Change{
		Symbols:    []Symbol{{Name: "Alone", Kind: "type", File: "x.go", Line: 1}},
		Candidates: map[string][]string{},
	}
	if got := duplicationSubject(change); !strings.Contains(got, "candidates: none found") {
		t.Errorf("got:\n%s", got)
	}
}

func TestFirstLine(t *testing.T) {
	if got := firstLine("one\ntwo"); got != "one" {
		t.Errorf("got %q", got)
	}
	long := strings.Repeat("x", 200)
	got := firstLine(long)
	if len([]rune(got)) != 141 || !strings.HasSuffix(got, "…") {
		t.Errorf("a long line is cut, got %d runes", len([]rune(got)))
	}
}

func TestShort(t *testing.T) {
	lines := []string{"a", "b", "c"}
	if got := short(lines, 2); len(got) != 2 {
		t.Errorf("got %v", got)
	}
	if got := short(lines, 9); len(got) != 3 {
		t.Errorf("got %v", got)
	}
}

// still is a provider that answers with whatever it was handed, so the whole
// path from an answer to a finding can be walked without a model.
type still struct {
	answer string
	system string
	user   string
}

func (s *still) Name() string { return "still" }

func (s *still) Ask(ctx context.Context, system, user string) (Answer, error) {
	s.system, s.user = system, user
	return Answer{Text: s.answer}, nil
}

func TestReviewerReadsAnAnswer(t *testing.T) {
	provider := &still{answer: "Sure! ```json\n{\"findings\":[" +
		`{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"message":"m","fix":"f"},` +
		`{"rule":"made-up","severity":"must-fix","message":"dropped"}` +
		"]}\n```"}
	change := &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider}.Run(context.Background(), change, jobs)
	if len(result.Failures) != 0 {
		t.Fatalf("failures: %v", result.Failures)
	}
	if len(result.Findings) != 1 || result.Findings[0].Rule != "cannot-fail" {
		t.Fatalf("got %v", result.Findings)
	}
	// The criteria are the system prompt, where a provider that caches
	// anything will cache them.
	if !strings.Contains(provider.system, instruction) || !strings.Contains(provider.system, "cannot-fail") {
		t.Errorf("the system prompt is missing the instruction or the criteria:\n%s", provider.system)
	}
	if !strings.Contains(provider.user, "TestX") {
		t.Errorf("the subject never reached the provider:\n%s", provider.user)
	}
}

func TestReviewerReportsABadAnswer(t *testing.T) {
	change := &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: &still{answer: "I would rather not."}}.Run(context.Background(), change, jobs)
	if len(result.Failures) != 1 {
		t.Fatalf("got %v, want one failure", result.Failures)
	}
	if !strings.Contains(result.Failures[0].Error(), "tests:") {
		t.Errorf("a failure names its job, got %q", result.Failures[0])
	}
}

// One job failing does not stop the others: four readings out of five is
// worth more than none.
func TestReviewerKeepsGoingAfterAFailure(t *testing.T) {
	change := &Change{
		Tests:    []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}},
		Comments: []Located{{Text: "Windows rejects this.", File: "x.go", Line: 1}},
	}
	jobs, err := chosen("tests,claims")
	if err != nil {
		t.Fatal(err)
	}
	provider := &refusing{good: "claims"}
	result := Reviewer{Provider: provider}.Run(context.Background(), change, jobs)
	if len(result.Failures) != 1 {
		t.Fatalf("failures: %v", result.Failures)
	}
	if len(result.Findings) != 1 || result.Findings[0].Job != "claims" {
		t.Fatalf("got %v, want the reading that worked", result.Findings)
	}
}

// refusing answers only the job whose criteria it recognises.
type refusing struct{ good string }

func (r *refusing) Name() string { return "refusing" }

func (r *refusing) Ask(ctx context.Context, system, user string) (Answer, error) {
	if r.good == "claims" && strings.Contains(system, "unsupported-claim") {
		return Answer{Text: `{"findings":[{"rule":"unsupported-claim","severity":"note","file":"x.go","line":1,"message":"m","fix":"f"}]}`}, nil
	}
	return Answer{}, context.Canceled
}

// A reading finds one same-value pair and stops when the pairs are buried
// among the resemblances, so they are rendered first and alone.
func TestDuplicationSubjectLeadsWithTheTwins(t *testing.T) {
	change := &Change{
		Symbols: []Symbol{
			{Name: "typeIconGroup", Kind: "value", File: "exe/exe.go", Line: 32, Signature: "typeIconGroup = 14"},
			{Name: "groupHeaderSize", Kind: "value", File: "exe/exe.go", Line: 44, Signature: "groupHeaderSize = 6"},
		},
		Twins: map[string][]string{
			"typeIconGroup":   {"exe/exe.go:47: groupEntrySize = 14   <- same value"},
			"groupHeaderSize": {"ico/writer.go:15: directorySize = 6   <- same value"},
		},
		Candidates: map[string][]string{
			"groupHeaderSize": {"ico/writer.go:15: directorySize = 6   <- same value", "exe/exe.go:53: type Group struct {"},
		},
	}
	got := duplicationSubject(change)
	list, detail, found := strings.Cut(got, "Each name the change adds")
	if !found {
		t.Fatalf("no detail section in:\n%s", got)
	}
	for _, want := range []string{"groupEntrySize = 14", "directorySize = 6", "exe/exe.go:44"} {
		if !strings.Contains(list, want) {
			t.Errorf("%q missing from the list of pairs:\n%s", want, list)
		}
	}
	// The pairs are declared in the order the change declares them, so two
	// readings of the same change see the same list.
	if strings.Index(list, "typeIconGroup") > strings.Index(list, "groupHeaderSize") {
		t.Errorf("the pairs are out of order:\n%s", list)
	}
	if !strings.Contains(detail, "type Group struct {") {
		t.Errorf("the resemblances are gone:\n%s", detail)
	}
}

func TestDuplicationSubjectWithoutTwins(t *testing.T) {
	change := &Change{
		Symbols:    []Symbol{{Name: "Alone", Kind: "type", File: "x.go", Line: 1}},
		Twins:      map[string][]string{},
		Candidates: map[string][]string{},
	}
	if got := duplicationSubject(change); strings.Contains(got, "already declared elsewhere") {
		t.Errorf("a change with no pairs is not asked about them:\n%s", got)
	}
}

// A provider that cannot be held to a schema sometimes describes its
// findings instead of reporting them. Losing the whole reading to that is
// worse than asking again.
func TestReviewerAsksAgainForAnAnswerItCanRead(t *testing.T) {
	provider := &relenting{
		answers: []string{
			"Reported two findings: `Stored` (must-fix) and `largest` (consider).",
			`{"findings":[{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"message":"m","fix":"f"}]}`,
		},
	}
	change := &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider}.Run(context.Background(), change, jobs)
	if len(result.Failures) != 0 {
		t.Fatalf("failures: %v", result.Failures)
	}
	if len(result.Findings) != 1 || result.Findings[0].Rule != "cannot-fail" {
		t.Fatalf("got %v", result.Findings)
	}
	if len(provider.asked) != 2 {
		t.Fatalf("asked %d times, want two", len(provider.asked))
	}
	if !strings.Contains(provider.asked[1], again) {
		t.Errorf("the second question does not say what was wrong:\n%s", provider.asked[1])
	}
	// The subject is asked again, not only the correction.
	if !strings.Contains(provider.asked[1], "TestX") {
		t.Errorf("the subject was dropped from the second question:\n%s", provider.asked[1])
	}
}

// It is asked twice and no more: a provider that will not answer in JSON
// will not do so on the third try either.
func TestReviewerGivesUpAfterAskingTwice(t *testing.T) {
	provider := &relenting{answers: []string{"no", "still no"}}
	change := &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider}.Run(context.Background(), change, jobs)
	if len(result.Failures) != 1 {
		t.Fatalf("got %v, want one failure", result.Failures)
	}
	// The first answer is the one worth seeing: the second was made under
	// duress.
	if !strings.Contains(result.Failures[0].Error(), "no") || !strings.Contains(result.Failures[0].Error(), "twice") {
		t.Errorf("got %q", result.Failures[0])
	}
	if len(provider.asked) != 2 {
		t.Errorf("asked %d times, want two", len(provider.asked))
	}
}

// relenting answers each question with the next answer it was given.
type relenting struct {
	answers []string
	asked   []string
}

func (r *relenting) Name() string { return "relenting" }

func (r *relenting) Ask(ctx context.Context, system, user string) (Answer, error) {
	r.asked = append(r.asked, user)
	if len(r.asked) > len(r.answers) {
		return Answer{}, fmt.Errorf("asked once too often")
	}
	return Answer{Text: r.answers[len(r.asked)-1]}, nil
}

// The tests job is pointed at a skip, and shown the functions the tests
// call, so that whether a test passes on a stub is judged against the
// function.
func TestTestsSubjectShowsTheSkipAndTheCodeUnderTest(t *testing.T) {
	change := &Change{
		Tests: []Function{{Name: "TestDecode", File: "x_test.go", Line: 5, Skips: 7, Body: "func TestDecode(t *testing.T) {\n\tif !have {\n\t\tt.Skip()\n\t}\n\tgot := decode(in)\n\tcheck(t, got)\n}"}},
		index: []Declared{
			{Name: "decode", Kind: "func", File: "x.go", Line: 3, Body: "func decode(b []byte) []byte {\n\treturn b\n}"},
			{Name: "check", Kind: "func", File: "x_test.go", Line: 30, Body: "func check(t *testing.T, b []byte) {}"},
		},
	}
	got := testsSubject(change)
	for _, want := range []string{"(skips itself at line 7)", "Functions the tests call", "--- x.go:3 decode", "return b"} {
		if !strings.Contains(got, want) {
			t.Errorf("%q missing from:\n%s", want, got)
		}
	}
	if strings.Contains(got, "x_test.go:30") {
		t.Errorf("a test file's helper was shown as code under test:\n%s", got)
	}
}

// The claims job reads each comment beside the code it sits above, in the
// blocks the comments were written as, without the ones that only narrate.
func TestClaimsSubjectShowsTheCodeBelow(t *testing.T) {
	change := &Change{Comments: []Located{
		{Text: "set the name", File: "x.go", Line: 3, Below: "setName(x)"},
		{Text: "Windows refuses an unordered group, so", File: "x.go", Line: 7, Below: "sort(rows)"},
		{Text: "the rows are sorted first.", File: "x.go", Line: 8, Below: "sort(rows)"},
	}}
	got := claimsSubject(change)
	if strings.Contains(got, "set the name") {
		t.Errorf("a narrating comment reached the claims job:\n%s", got)
	}
	if strings.Count(got, "code: sort(rows)") != 1 {
		t.Errorf("the code below a block is shown once:\n%s", got)
	}
	if !strings.Contains(got, "x.go:7") || !strings.Contains(got, "x.go:8") {
		t.Errorf("the block is incomplete:\n%s", got)
	}
}
