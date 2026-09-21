package main

// The second reading is what stands behind a finding. These tests hold the
// contract both ways: a verdict that holds keeps the finding and marks it
// verified, a verdict that falls retracts the finding with its reason, and
// a verdict that cannot be asked fails open — the finding stands, marked
// unverified, and the failure joins the others rather than ending the run.

import (
	"context"
	"strings"
	"testing"
)

func findingsJSON(rules ...string) string {
	var b strings.Builder
	b.WriteString(`{"findings":[`)
	for i, r := range rules {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"rule":"` + r + `","severity":"must-fix","file":"x_test.go","line":4,"message":"m","fix":"f"}`)
	}
	b.WriteString(`]}`)
	return b.String()
}

func verdictJSON(pairs ...string) string {
	var b strings.Builder
	b.WriteString(`{"verdicts":[`)
	for i, p := range pairs {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(p)
	}
	b.WriteString(`]}`)
	return b.String()
}

func verifyChange() *Change {
	return &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 3, Body: "func TestX(t *testing.T) {}"}}}
}

func TestVerifyLetsAReadingStand(t *testing.T) {
	provider := &relenting{answers: []string{
		findingsJSON("cannot-fail"),
		verdictJSON(`{"index":0,"holds":true,"reason":""}`),
	}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Failures) != 0 {
		t.Fatalf("failures: %v", result.Failures)
	}
	if len(result.Findings) != 1 || !result.Findings[0].Verified {
		t.Fatalf("got %+v", result.Findings)
	}
	if len(result.Retracted) != 0 {
		t.Fatalf("retracted %+v", result.Retracted)
	}
	// The verdict is asked against the same evidence the finding came from,
	// not against the finding alone.
	if len(provider.asked) != 2 {
		t.Fatalf("asked %d times, want two", len(provider.asked))
	}
	for _, want := range []string{"TestX", "cannot-fail"} {
		if !strings.Contains(provider.asked[1], want) {
			t.Errorf("%q missing from the verdict's evidence:\n%s", want, provider.asked[1])
		}
	}
}

func TestVerifyRetracts(t *testing.T) {
	provider := &relenting{answers: []string{
		findingsJSON("cannot-fail"),
		verdictJSON(`{"index":0,"holds":false,"reason":"the test cannot fail"}`),
	}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Failures) != 0 {
		t.Fatalf("failures: %v", result.Failures)
	}
	if len(result.Findings) != 0 {
		t.Fatalf("kept %+v", result.Findings)
	}
	if len(result.Retracted) != 1 {
		t.Fatalf("got %+v", result.Retracted)
	}
	r := result.Retracted[0]
	if r.Reason != "the test cannot fail" || r.Finding.Rule != "cannot-fail" {
		t.Errorf("got %+v", r)
	}
}

// A verdict that cannot be asked is not a verdict: the findings stand,
// marked as what they are, and the failure is reported like any other.
func TestVerifyFailsOpen(t *testing.T) {
	provider := &relenting{answers: []string{findingsJSON("cannot-fail")}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Findings) != 1 {
		t.Fatalf("kept %+v", result.Findings)
	}
	if result.Findings[0].Verified {
		t.Error("a finding no second reading saw is marked verified")
	}
	if len(result.Failures) != 1 || !strings.Contains(result.Failures[0].Error(), "verify/tests:") {
		t.Fatalf("got %v", result.Failures)
	}
}

// A verdict list that omits a finding stands rather than falls for it: a
// strict pass would let one dropped number retract everything.
func TestVerifyStandsForAnOmittedVerdict(t *testing.T) {
	provider := &relenting{answers: []string{
		findingsJSON("cannot-fail", "skips-in-normal-conditions"),
		verdictJSON(`{"index":0,"holds":true,"reason":""}`),
	}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Findings) != 2 {
		t.Fatalf("kept %+v", result.Findings)
	}
	for _, f := range result.Findings {
		if !f.Verified {
			t.Errorf("%s stands unverified", f.Rule)
		}
	}
}

// A provider that answers the verdict in prose is asked once more, the way
// the findings are.
func TestVerifyAsksTwiceForProse(t *testing.T) {
	provider := &relenting{answers: []string{
		findingsJSON("cannot-fail"),
		"The finding holds.",
		verdictJSON(`{"index":0,"holds":false,"reason":"the test can fail"}`),
	}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider, Verify: true}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Retracted) != 1 || len(result.Findings) != 0 {
		t.Fatalf("got %+v kept, %+v retracted", result.Findings, result.Retracted)
	}
	if len(provider.asked) != 3 {
		t.Fatalf("asked %d times, want three", len(provider.asked))
	}
	if !strings.Contains(provider.asked[2], verdictsAgain) {
		t.Errorf("the retry does not say what was wrong:\n%s", provider.asked[2])
	}
}

// Without the second reading the findings are what they were read as: seen
// once, by the reading that reported them.
func TestVerifyOffLeavesFindingsUnverified(t *testing.T) {
	provider := &relenting{answers: []string{findingsJSON("cannot-fail")}}
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	result := Reviewer{Provider: provider}.Run(context.Background(), verifyChange(), jobs)
	if len(result.Findings) != 1 || result.Findings[0].Verified {
		t.Fatalf("got %+v", result.Findings)
	}
}
