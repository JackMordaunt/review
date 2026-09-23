package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
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
	// Splittable is whether the job's subject can be read file by file: a
	// subject over the packet cap is then asked in parts, each cached on
	// its own, rather than as one ask a slow provider cannot finish.
	Splittable bool
}

// Jobs are the readings, in the order their findings are worth having.
func Jobs() []Job {
	return []Job{
		{Name: "duplication", Criteria: read("duplication"), Subject: duplicationSubject, Splittable: true},
		{Name: "tests", Criteria: read("tests"), Subject: testsSubject, Splittable: true},
		{Name: "namer", Criteria: read("namer"), Subject: namerSubject, Splittable: true},
		{Name: "claims", Criteria: read("claims"), Subject: claimsSubject, Splittable: true},
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
	// The pairs holding the same literal go first and alone. Buried among
	// the resemblances a reading finds one of them and stops.
	if twinned := twins(c); twinned != "" {
		b.WriteString("Declarations this change adds that hold a value already declared elsewhere.\n")
		b.WriteString("Judge every pair on this list.\n\n")
		b.WriteString(twinned)
		b.WriteString("\n")
	}
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

// twins renders the declarations whose value already exists, in the order the
// change declares them.
func twins(c *Change) string {
	var b strings.Builder
	for _, s := range c.Symbols {
		lines := c.Twins[s.Name]
		if len(lines) == 0 {
			continue
		}
		fmt.Fprintf(&b, "  %s:%d  %s\n", s.File, s.Line, s.Signature)
		for _, line := range lines {
			fmt.Fprintf(&b, "      %s\n", strings.TrimSuffix(line, "   <- same value"))
		}
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
		fmt.Fprintf(&b, "--- %s:%d %s", t.File, t.Line, t.Name)
		if t.Skips > 0 {
			// The skip is pointed at rather than left to be found, so the
			// reading spends itself on whether the skip is ordinary.
			fmt.Fprintf(&b, "  (skips itself at line %d)", t.Skips)
		}
		fmt.Fprintf(&b, "\n%s\n\n", t.Body)
	}
	if called := functionsUnderTest(c); called != "" {
		b.WriteString("Functions the tests call, as they stand at the end of the change. A test that\n")
		b.WriteString("would pass with one of these returning its input or a zero value is the finding.\n\n")
		b.WriteString(called)
	}
	return b.String()
}

// The bounds on what the tests job is shown of the code under test: how
// many functions, and how long each may be before it is cut.
const (
	calledFunctions = 8
	calledLines     = 60
)

// functionsUnderTest renders the functions the tests call, found by name in
// the repository's index, so that whether a test would pass on a stub is
// judged against the function rather than guessed from the test. The
// functions are the ones declared outside the tests: a helper a test file
// declares is in the test's own file, and is not the code under test.
func functionsUnderTest(c *Change) string {
	if len(c.index) == 0 {
		return ""
	}
	declared := map[string]Declared{}
	for _, d := range c.index {
		if d.Kind == "func" && d.Body != "" && !isTestFile(d.File) {
			if _, taken := declared[d.Name]; !taken {
				declared[d.Name] = d
			}
		}
	}
	seen := map[string]bool{}
	var shown []Declared
	for _, t := range c.Tests {
		for _, m := range call.FindAllStringSubmatch(t.Body, -1) {
			name := m[1]
			d, ok := declared[name]
			if !ok || seen[name] || name == t.Name {
				continue
			}
			seen[name] = true
			shown = append(shown, d)
			if len(shown) == calledFunctions {
				break
			}
		}
		if len(shown) == calledFunctions {
			break
		}
	}
	if len(shown) == 0 {
		return ""
	}
	var b strings.Builder
	for _, d := range shown {
		body := d.Body
		if lines := strings.Split(body, "\n"); len(lines) > calledLines {
			body = strings.Join(lines[:calledLines], "\n") + "\n\t… cut at " + fmt.Sprint(calledLines) + " lines"
		}
		fmt.Fprintf(&b, "--- %s:%d %s\n%s\n\n", d.File, d.Line, d.Name, body)
	}
	return b.String()
}

// call matches a call by name, which is how a test names what it tests.
var call = regexp.MustCompile(`\b([A-Za-z_][A-Za-z0-9_]*)\(`)

func claimsSubject(c *Change) string {
	blocks := commentBlocks(c.Comments)
	if len(blocks) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("Comment and documentation lines this change adds, each with the code beneath it:\n\n")
	for _, block := range blocks {
		for _, comment := range block {
			fmt.Fprintf(&b, "%s:%d  %s\n", comment.File, comment.Line, comment.Text)
		}
		if below := block[len(block)-1].Below; below != "" {
			for line := range strings.SplitSeq(below, "\n") {
				fmt.Fprintf(&b, "    code: %s\n", line)
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

// commentBlocks groups the comments into the runs of consecutive lines
// they were written as, so a claim read over three lines is read whole and
// the code below it is shown once. A comment whose words are the code's
// own is left out: it is never a claim, and measured elsewhere.
func commentBlocks(comments []Located) [][]Located {
	var blocks [][]Located
	for _, comment := range comments {
		if restates(comment) {
			continue
		}
		n := len(blocks)
		if n > 0 {
			last := blocks[n-1][len(blocks[n-1])-1]
			if last.File == comment.File && last.Line+1 == comment.Line {
				blocks[n-1] = append(blocks[n-1], comment)
				continue
			}
		}
		blocks = append(blocks, []Located{comment})
	}
	return blocks
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

// packetCap is the size of subject past which a splittable job is asked in
// parts. The tests packet of one seven-file change measured 22 KB and was
// killed at the ask timeout on a slow gateway; under the cap each part is
// an ask that gateway finishes, and a part whose files did not change
// replays from the cache while the others are asked.
const packetCap = 16000

// parts is the subjects a job is asked, as changes: the whole change when
// it fits or cannot be split, else the change cut file by file into runs
// that each render under the cap. A file that alone renders over the cap
// is a part by itself.
func parts(job Job, c *Change) []*Change {
	if !job.Splittable || len(job.Subject(c)) <= packetCap {
		return []*Change{c}
	}
	var (
		out   []*Change
		group []string
	)
	for _, file := range c.Files {
		if !c.contributes(file) {
			continue
		}
		if len(group) > 0 && len(job.Subject(c.part(append(slices.Clone(group), file)))) > packetCap {
			out = append(out, c.part(group))
			group = nil
		}
		group = append(group, file)
	}
	if len(group) > 0 {
		out = append(out, c.part(group))
	}
	return out
}

// contributes is whether a file has anything a splittable job reads.
func (c *Change) contributes(file string) bool {
	for _, s := range c.Symbols {
		if s.File == file {
			return true
		}
	}
	for _, t := range c.Tests {
		if t.File == file {
			return true
		}
	}
	for _, comment := range c.Comments {
		if comment.File == file {
			return true
		}
	}
	return false
}

// part is the change narrowed to some of its files: the declarations,
// tests and comments in them, with everything the jobs read beside those
// — candidates, twins, the index, the message — shared.
func (c *Change) part(files []string) *Change {
	keep := map[string]bool{}
	for _, f := range files {
		keep[f] = true
	}
	p := *c
	p.Files = slices.Clone(files)
	p.Symbols, p.Tests, p.Comments = nil, nil, nil
	for _, s := range c.Symbols {
		if keep[s.File] {
			p.Symbols = append(p.Symbols, s)
		}
	}
	for _, t := range c.Tests {
		if keep[t.File] {
			p.Tests = append(p.Tests, t)
		}
	}
	for _, comment := range c.Comments {
		if keep[comment.File] {
			p.Comments = append(p.Comments, comment)
		}
	}
	return &p
}
