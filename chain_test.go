package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

// stub answers from a script: each ask consumes the next outcome, and the
// count records how far a chain walked.
type stub struct {
	outcomes []string // one per ask: "" means error, "ok" means text
	asks     int
	label    string
}

func (s *stub) Name() string { return s.label }

func (s *stub) Ask(ctx context.Context, system, user string) (Answer, error) {
	s.asks++
	outcome := "error"
	if s.asks <= len(s.outcomes) {
		outcome = s.outcomes[s.asks-1]
	}
	switch outcome {
	case "ok":
		return Answer{Text: "OK"}, nil
	case "empty":
		return Answer{}, nil
	default:
		return Answer{}, fmt.Errorf("429: too many requests")
	}
}

func chainOf(entries ...*stub) Chain {
	out := Chain{}
	for _, p := range entries {
		out = append(out, entry{Name: p.label, Provider: p})
	}
	return out
}

func TestChainPicksTheFirstThatAnswers(t *testing.T) {
	first, second := &stub{label: "first", outcomes: []string{"ok"}}, &stub{label: "second", outcomes: []string{"ok"}}
	provider, name, err := chainOf(first, second).pick(context.Background(), func(string) {})
	if err != nil {
		t.Fatalf("pick: %v", err)
	}
	if name != "first" || provider != Provider(first) {
		t.Fatalf("picked %q, want the first entry", name)
	}
	if first.asks != 1 || second.asks != 0 {
		t.Fatalf("asks: first %d, second %d, want 1 and 0", first.asks, second.asks)
	}
}

func TestChainSkipsAFailingProvider(t *testing.T) {
	first, second := &stub{label: "first", outcomes: []string{"error"}}, &stub{label: "second", outcomes: []string{"ok"}}
	var warned []string
	provider, name, err := chainOf(first, second).pick(context.Background(), func(s string) { warned = append(warned, s) })
	if err != nil || name != "second" || provider != Provider(second) {
		t.Fatalf("pick: %v, %q", err, name)
	}
	if first.asks != 1 || second.asks != 1 {
		t.Fatalf("asks: first %d, second %d", first.asks, second.asks)
	}
	if len(warned) != 1 || !strings.Contains(warned[0], "too many requests") {
		t.Fatalf("warned %q, want the failure reason", warned)
	}
}

func TestChainSkipsAnEmptyAnswer(t *testing.T) {
	first, second := &stub{label: "first", outcomes: []string{"empty"}}, &stub{label: "second", outcomes: []string{"ok"}}
	provider, name, err := chainOf(first, second).pick(context.Background(), func(string) {})
	if err != nil {
		t.Fatalf("pick: %v", err)
	}
	if name != "second" || provider != Provider(second) {
		t.Fatalf("picked %q, want the second entry", name)
	}
	if first.asks != 1 || second.asks != 1 {
		t.Fatalf("asks: first %d, second %d", first.asks, second.asks)
	}
}

func TestChainReportsEveryReasonWhenAllFail(t *testing.T) {
	first, second := &stub{label: "first", outcomes: []string{"error"}}, &stub{label: "second", outcomes: []string{"empty"}}
	_, _, err := chainOf(first, second).pick(context.Background(), func(string) {})
	if err == nil {
		t.Fatal("pick: want an error naming every entry")
	}
	for _, want := range []string{"first", "second", "too many requests", "answered nothing"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("pick: %v, want it to name %q", err, want)
		}
	}
}
