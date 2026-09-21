package main

import (
	"bufio"
	"cmp"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Severity is what a finding means for the change.
type Severity int

// The severities, most serious first. Only MustFix is worth blocking on; the
// rest are reported and left to judgement, because a loop that treats taste
// as an error never finishes.
const (
	MustFix Severity = iota
	Consider
	Note
)

func (s Severity) String() string {
	switch s {
	case MustFix:
		return "must-fix"
	case Consider:
		return "consider"
	case Note:
		return "note"
	}
	return "unknown"
}

// ParseSeverity reads a severity the way a job reports it, defaulting to the
// least serious rather than failing: a job that invents a word should not
// stop the run.
func ParseSeverity(s string) Severity {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "must-fix", "must fix", "mustfix", "error":
		return MustFix
	case "consider", "warning":
		return Consider
	}
	return Note
}

// Finding is one thing a job noticed.
type Finding struct {
	// Job is the job that reported it.
	Job string `json:"job"`
	// Rule is the criterion it was judged against. A finding that cites no
	// rule is dropped, so that the criteria are what gets tuned rather than
	// the prompt.
	Rule string `json:"rule"`
	// Severity is how seriously to take it.
	Severity Severity `json:"-"`
	// SeverityName is how it travels in and out of JSON.
	SeverityName string `json:"severity"`
	// File and Line locate it, where it has a location.
	File string `json:"file,omitempty"`
	Line int    `json:"line,omitempty"`
	// Symbol names what it concerns, for the findings that are about a name
	// rather than a place.
	Symbol string `json:"symbol,omitempty"`
	// Message states the finding.
	Message string `json:"message"`
	// Fix is the concrete change suggested, which is what lets an agent act
	// on the finding rather than reason about it again.
	Fix string `json:"fix,omitempty"`
}

func (f Finding) String() string {
	var b strings.Builder
	b.WriteString(f.Severity.String())
	b.WriteString(": ")
	if f.File != "" {
		b.WriteString(f.File)
		if f.Line > 0 {
			fmt.Fprintf(&b, ":%d", f.Line)
		}
		b.WriteString(": ")
	} else if f.Symbol != "" {
		b.WriteString(f.Symbol)
		b.WriteString(": ")
	}
	b.WriteString(f.Message)
	if f.Fix != "" {
		b.WriteString("\n      → ")
		b.WriteString(f.Fix)
	}
	b.WriteString("\n      [")
	b.WriteString(f.Job)
	b.WriteString("/")
	b.WriteString(f.Rule)
	b.WriteString("]")
	return b.String()
}

// Sort orders findings so the ones worth reading first are first.
func Sort(findings []Finding) {
	slices.SortStableFunc(findings, func(a, b Finding) int {
		if order := cmp.Compare(a.Severity, b.Severity); order != 0 {
			return order
		}
		if order := cmp.Compare(a.File, b.File); order != 0 {
			return order
		}
		return cmp.Compare(a.Line, b.Line)
	})
}

// ignore matches the comment that dismisses a finding. It lives in the source
// beside what it justifies, rather than in a file of its own, so that the
// reason is where a reader needs it and survives a clone.
//
//	//review:ignore <rule> <why>
var ignore = regexp.MustCompile(`//\s*review:ignore\s+(\S+)(?:\s+(.*))?`)

// Suppressed reports whether the source dismisses a finding, and with what
// reason. A dismissal on or just above the line it concerns covers that line;
// one anywhere in a file covers the findings that name no line.
func Suppressed(f Finding) (string, bool) {
	if f.File == "" {
		return "", false
	}
	file, err := os.Open(f.File)
	if err != nil {
		return "", false
	}
	defer file.Close()

	var (
		scanner = bufio.NewScanner(file)
		line    int
	)
	for scanner.Scan() {
		line++
		match := ignore.FindStringSubmatch(scanner.Text())
		if match == nil || !rulesMatch(match[1], f.Rule) {
			continue
		}
		why := strings.TrimSpace(match[2])
		if why == "" {
			why = "no reason given"
		}
		// A dismissal with no line to answer to covers the file; otherwise it
		// has to sit within a few lines of what it dismisses, so that moving
		// code does not carry a dismissal somewhere it was never meant.
		if f.Line == 0 || (line >= f.Line-3 && line <= f.Line+1) {
			return why, true
		}
	}
	return "", false
}

// rulesMatch compares a dismissal against a rule, where "all" dismisses
// anything the job found at that spot.
func rulesMatch(dismissed, rule string) bool {
	return dismissed == "all" || strings.EqualFold(dismissed, rule)
}

// atoi reads a line number a job reported, which may arrive as a string.
func atoi(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return n
}
