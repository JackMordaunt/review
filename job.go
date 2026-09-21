package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"strings"
)

//go:embed criteria/*.md
var criteria embed.FS

// Job is one narrow reading of a change. Each is given the part of the change
// it needs and nothing else: a job that reads less is cheaper, and harder to
// distract into reporting something another job owns.
type Job struct {
	// Name is how it is asked for and how its findings are labelled.
	Name string
	// Criteria is the rules it judges against, and the thing to tune when it
	// reports the wrong things.
	Criteria string
	// Subject renders the part of the change this job reads. An empty string
	// means there is nothing here for it and the job is skipped, which is
	// what keeps a documentation-only commit from paying for a test review.
	Subject func(*Change) string
}

// Jobs are the readings, in the order their findings are worth having.
func Jobs() []Job {
	return []Job{
		{Name: "duplication", Criteria: read("duplication"), Subject: duplicationSubject},
		{Name: "tests", Criteria: read("tests"), Subject: testsSubject},
		{Name: "namer", Criteria: read("namer"), Subject: namerSubject},
		{Name: "claims", Criteria: read("claims"), Subject: claimsSubject},
		{Name: "hygiene", Criteria: read("hygiene"), Subject: hygieneSubject},
	}
}

func read(name string) string {
	data, err := criteria.ReadFile("criteria/" + name + ".md")
	if err != nil {
		panic(err) // The criteria are embedded; a missing one is a build fault.
	}
	return string(data)
}

func namerSubject(c *Change) string {
	if len(c.Symbols) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("Names this change adds or renames:\n\n")
	for _, s := range c.Symbols {
		fmt.Fprintf(&b, "%s:%d  %s %s", s.File, s.Line, s.Kind, s.Name)
		if s.Exported {
			b.WriteString("  (exported)")
		}
		b.WriteString("\n")
		if s.Signature != "" {
			fmt.Fprintf(&b, "    %s\n", s.Signature)
		}
		if s.Doc != "" {
			fmt.Fprintf(&b, "    doc: %s\n", firstLine(s.Doc))
		}
		if near := c.Candidates[s.Name]; len(near) > 0 {
			fmt.Fprintf(&b, "    names already in this repository: %s\n", strings.Join(short(near, 6), "; "))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func duplicationSubject(c *Change) string {
	if len(c.Symbols) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("Each name the change adds, with existing declarations found by searching for its words.\n\n")
	for _, s := range c.Symbols {
		fmt.Fprintf(&b, "NEW  %s:%d  %s %s\n", s.File, s.Line, s.Kind, s.Name)
		if s.Signature != "" {
			fmt.Fprintf(&b, "     %s\n", s.Signature)
		}
		if s.Doc != "" {
			fmt.Fprintf(&b, "     doc: %s\n", firstLine(s.Doc))
		}
		candidates := c.Candidates[s.Name]
		if len(candidates) == 0 {
			b.WriteString("     candidates: none found\n\n")
			continue
		}
		b.WriteString("     candidates:\n")
		for _, line := range candidates {
			fmt.Fprintf(&b, "       %s\n", line)
		}
		b.WriteString("\n")
	}
	return b.String()
}

func testsSubject(c *Change) string {
	if len(c.Tests) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("Test functions this change adds or alters:\n\n")
	for _, t := range c.Tests {
		fmt.Fprintf(&b, "--- %s:%d %s\n%s\n\n", t.File, t.Line, t.Name, t.Body)
	}
	return b.String()
}

func claimsSubject(c *Change) string {
	if len(c.Comments) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("Comment and documentation lines this change adds:\n\n")
	for _, comment := range c.Comments {
		fmt.Fprintf(&b, "%s:%d  %s\n", comment.File, comment.Line, comment.Text)
	}
	return b.String()
}

func hygieneSubject(c *Change) string {
	if strings.TrimSpace(c.Message) == "" {
		return ""
	}
	var b strings.Builder
	b.WriteString("Commit message:\n\n")
	b.WriteString(c.Message)
	b.WriteString("\n\nFiles changed:\n")
	b.WriteString(c.Stat)
	if len(c.Convention) > 0 {
		b.WriteString("\nRecent subjects in this repository, as the local convention:\n")
		for _, subject := range c.Convention {
			fmt.Fprintf(&b, "  %s\n", subject)
		}
	}
	return b.String()
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 140 {
		s = s[:140] + "…"
	}
	return s
}

func short(lines []string, n int) []string {
	if len(lines) > n {
		lines = lines[:n]
	}
	return lines
}

// reported is the shape a job answers in. It is enforced by the schema rather
// than asked for in prose, so a malformed answer is impossible rather than
// merely unlikely.
type reported struct {
	Findings []struct {
		Rule     string `json:"rule"`
		Severity string `json:"severity"`
		File     string `json:"file"`
		Line     int    `json:"line"`
		Symbol   string `json:"symbol"`
		Message  string `json:"message"`
		Fix      string `json:"fix"`
	} `json:"findings"`
}

func (r reported) findings(job string, rules map[string]bool) []Finding {
	var out []Finding
	for _, f := range r.Findings {
		// A finding that cites no rule from the criteria is dropped: the
		// criteria are what gets tuned, so a job may not invent one.
		if !rules[f.Rule] {
			continue
		}
		out = append(out, Finding{
			Job: job, Rule: f.Rule,
			Severity: ParseSeverity(f.Severity), SeverityName: f.Severity,
			File: f.File, Line: f.Line, Symbol: f.Symbol,
			Message: f.Message, Fix: f.Fix,
		})
	}
	return out
}

func decode(raw string) (reported, error) {
	var r reported
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return reported{}, fmt.Errorf("reading the answer: %w", err)
	}
	return r, nil
}
