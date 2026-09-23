package main

import (
	"strings"
	"testing"
)

func TestPrintRules(t *testing.T) {
	all := capture(t, func() {
		if err := printRules(nil); err != nil {
			t.Error(err)
		}
	})
	for _, want := range []string{"# Deterministic checks", "`test-deleted`", "# Naming", "# Test integrity", "`cannot-fail`"} {
		if !strings.Contains(all, want) {
			t.Errorf("%q missing from the whole listing", want)
		}
	}
	job := capture(t, func() {
		if err := printRules([]string{"tests"}); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(job, "`cannot-fail`") || strings.Contains(job, "# Naming") {
		t.Errorf("the tests criteria were not printed alone:\n%s", job)
	}
	one := capture(t, func() {
		if err := printRules([]string{"noun-for-type"}); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(one, "from the namer criteria") || !strings.Contains(one, "reads wrong in the plural") {
		t.Errorf("the rule was not printed with its continuation:\n%s", one)
	}
	static := capture(t, func() {
		if err := printRules([]string{"duplicate-body"}); err != nil {
			t.Error(err)
		}
	})
	if !strings.Contains(static, "deterministic check") {
		t.Errorf("got %s", static)
	}
	if err := printRules([]string{"nothing-here"}); err == nil || !strings.Contains(err.Error(), "the jobs are") {
		t.Errorf("an unknown rule was not refused with the job names: %v", err)
	}
}

// Every deterministic check's rule id is described, so a finding can be
// looked up.
func TestEveryStaticRuleIsDescribed(t *testing.T) {
	described := map[string]bool{}
	for _, r := range staticRules {
		described[r.ID] = true
	}
	for _, id := range []string{
		"message-low-entropy", "message-boilerplate", "message-common-words", "message-frustration",
		"message-not-imperative", "message-no-body", "message-long-body", "message-names-unknown", "formatting-mixed-in", "assertion-always-true",
		"history-coupled-file", "suppression-added", "test-deleted", "no-stutter", "no-shadow",
		"abbreviation", "test-no-assertion", "duplicate-body", "function-too-long", "nesting-too-deep",
		"comment-restates-code", "todo-without-reference", "commented-out-code", "debug-leftover",
		"error-swallowed", "new-symbol-unreferenced", "code-without-tests", "go-build", "odin-check",
	} {
		if !described[id] {
			t.Errorf("%s is not described", id)
		}
	}
}

func TestPrintDismissals(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n\n//review:ignore no-stutter the idiom\nvar a = 1\n\n//review:ignore abbreviation\nvar cfg = 2\n\n//review:ignore no-stutter again\nvar b = 3\n")
	r.write("readme.md", "//review:ignore <rule> <why> is the shape\n")
	r.commit("first", "x.go", "readme.md")
	t.Chdir(r.Root)
	out := capture(t, func() {
		if err := printRules([]string{"-dismissed"}); err != nil {
			t.Fatal(err)
		}
	})
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if !strings.HasPrefix(lines[0], "no-stutter") || !strings.Contains(lines[0], " 2") {
		t.Errorf("the most dismissed rule is not first:\n%s", out)
	}
	if !strings.Contains(out, "x.go:6  no reason given") || !strings.Contains(out, "x.go:3  the idiom") {
		t.Errorf("got:\n%s", out)
	}
	if strings.Contains(out, "<rule>") {
		t.Errorf("prose counted as a dismissal:\n%s", out)
	}
}
