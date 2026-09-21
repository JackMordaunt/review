package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// The eval set is the only thing here that spends money, so it is off unless
// asked for: go test -run TestEval -eval=1. More than one run per case is
// worth having, because a single reading walks between the two failure
// directions rather than sitting at one.
var (
	evalRuns  = flag.Int("eval", 0, "Run the eval set this many times per case. This asks a provider, and costs money.")
	evalCases = flag.String("eval.cases", "", "Run only the eval cases whose names contain this.")
	evalShow  = flag.Bool("eval.show", false, "Print every finding, not only the ones that scored.")
)

// A want is a finding the reading has to produce. The rule and the file are
// compared where they are given; About is the words that identify which
// duplicate, name or assertion is meant.
type want struct {
	Rule  string
	File  string
	About []string
}

func (w want) String() string {
	about := strings.Join(w.About, "+")
	if about == "" {
		about = "anything at all"
	}
	if w.File != "" {
		about += " in " + w.File
	}
	if w.Rule == "" {
		return about
	}
	return w.Rule + " about " + about
}

// matches reports whether a finding is the one wanted. The subject is looked
// for in what the finding says rather than where it says it, so that a case
// about one name is not answered by any finding in a file of that name.
func (w want) matches(f Finding) bool {
	if w.Rule != "" && f.Rule != w.Rule {
		return false
	}
	if w.File != "" && f.File != w.File {
		return false
	}
	text := strings.ToLower(strings.Join([]string{f.Message, f.Fix, f.Symbol}, " "))
	for _, about := range w.About {
		if !strings.Contains(text, strings.ToLower(about)) {
			return false
		}
	}
	return true
}

// An evalCase is one reading with a known right answer. The silences matter
// more than the wants: a reading that reports a true and unwanted thing is
// the failure this set exists to catch.
type evalCase struct {
	Name string
	// Corpus builds or names the repository to read.
	Corpus func(*testing.T) string
	Rev    string
	Jobs   string
	Want   []want
	// Silent is the subjects no finding may raise.
	Silent []want
	// Most is the largest number of findings the reading may report. Left
	// out, any number is allowed: it is the cases with one right answer that
	// need a ceiling.
	Most int
}

func evalSet() []evalCase {
	return []evalCase{{
		Name:   "duplication/layout-crosses-a-seam",
		Corpus: icns,
		Rev:    "ebed95f^..ebed95f",
		Jobs:   "duplication",
		Want: []want{
			{Rule: "layout-crosses-a-seam", About: []string{"groupHeaderSize"}},
			{About: []string{"icoEntrySize"}},
		},
		Silent: []want{
			// Per-package error sets are a deliberate convention here.
			{About: []string{"ErrNoIcons"}},
			// A resource type id and a row width are not the same fact
			// however equal they are.
			{About: []string{"typeIconGroup"}},
		},
	}, {
		Name:   "namer/adjective-for-a-type",
		Corpus: icns,
		Rev:    "6f52a0b^..6f52a0b",
		Jobs:   "namer",
		Want:   []want{{Rule: "noun-for-type", About: []string{"Stored"}}},
		Silent: []want{
			{About: []string{"maxIcons"}},
			{About: []string{"payload"}},
			{About: []string{"largest"}},
		},
		Most: 1,
	}, {
		// A purely mechanical loop rewrite. Every finding here is noise.
		Name:   "quiet/mechanical-rewrite",
		Corpus: icns,
		Rev:    "4c2e616^..4c2e616",
		Jobs:   "duplication,namer,claims",
		Silent: []want{{About: []string{""}}},
	}, {
		Name:   "tests/skips-in-normal-conditions",
		Corpus: synthetic,
		Rev:    "",
		Jobs:   "tests",
		Want:   []want{{Rule: "skips-in-normal-conditions", File: "shell_test.go"}},
		// No ceiling: the skipping test has one fault worth the name, but a
		// second reading of how weakly it asserts is a judgement the criteria
		// allow. The test that is meant to be good is the negative here.
		Silent: []want{{About: []string{"reverse"}}, {About: []string{"TestDecodeReverses"}}},
	}, {
		Name:   "claims/unsupported-claim",
		Corpus: synthetic,
		Rev:    "",
		Jobs:   "claims",
		Want:   []want{{Rule: "unsupported-claim", About: []string{"Windows"}}},
		Silent: []want{{File: "shell.go", About: []string{"decode"}}},
		Most:   1,
	}}
}

// icns is the corpus: a repository with rich history and known problems.
func icns(t *testing.T) string {
	t.Helper()
	root := os.Getenv("REVIEW_EVAL_CORPUS")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			t.Skip("no home directory to find the corpus in")
		}
		root = filepath.Join(home, "Source", "Personal", "icns")
	}
	if _, err := os.Stat(filepath.Join(root, ".git")); err != nil {
		t.Skipf("no corpus at %s; set REVIEW_EVAL_CORPUS", root)
	}
	return root
}

// synthetic is a repository written for the cases the corpus does not happen
// to contain.
func synthetic(t *testing.T) string {
	t.Helper()
	r := newRepo(t)
	r.write("go.mod", "module synthetic\n\ngo 1.27.0\n")
	r.write("shell.go", "package synthetic\n")
	r.write("shell_test.go", "package synthetic\n")
	r.commit("first", "go.mod", "shell.go", "shell_test.go")

	r.write("shell.go", `package synthetic

// Windows refuses an icon group whose rows are not ordered largest first, so
// the rows are sorted before they are written.
func order(rows []int) []int { return rows }

// decode reads the bitmap an icon holds, turning it the other way up.
func decode(data []byte) []byte {
	out := make([]byte, len(data))
	for i, b := range data {
		out[len(data)-1-i] = b
	}
	return out
}
`)
	r.write("shell_test.go", `package synthetic

import (
	"os/exec"
	"testing"
)

func TestAgainstIcotool(t *testing.T) {
	if _, err := exec.LookPath("icotool"); err != nil {
		t.Skip("icotool is not installed")
	}
	out, err := exec.Command("icotool", "--list", "testdata/one.ico").Output()
	if err != nil {
		t.Fatal(err)
	}
	const want = "--icon --index=1 --width=16 --height=16 --bit-depth=32\n"
	if string(out) != want {
		t.Fatalf("got %q, want %q", out, want)
	}
}

func TestDecodeReverses(t *testing.T) {
	got := decode([]byte{1, 2, 3})
	if len(got) != 3 || got[0] != 3 || got[1] != 2 || got[2] != 1 {
		t.Fatalf("got %v, want the bytes the other way up", got)
	}
}
`)
	r.stage("shell.go", "shell_test.go")
	return r.Root
}

// counting wraps a provider so a run can report what it spent.
type counting struct {
	Provider
	mu   sync.Mutex
	cost float64
	asks int
}

func (c *counting) Ask(ctx context.Context, system, user string) (Answer, error) {
	answer, err := c.Provider.Ask(ctx, system, user)
	c.mu.Lock()
	c.cost += answer.Cost
	c.asks++
	c.mu.Unlock()
	return answer, err
}

// score is one case's result over however many runs it was given. The
// subjects keep the order the case lists them in, so two scoreboards can be
// read side by side.
type score struct {
	Name string
	// Most is the largest number of findings any run reported, where that
	// was more than the case allows.
	Most     int
	Found    []tally
	Noise    []tally
	Failures int
}

// tally is how often one subject was raised across the runs.
type tally struct {
	Subject string
	Count   int
}

func TestEval(t *testing.T) {
	if *evalRuns <= 0 {
		t.Skip("the eval set asks a provider; run it with -eval=1")
	}
	which := orElse(os.Getenv("REVIEW_PROVIDER"), "claude")
	build, known := Providers()[which]
	if !known {
		t.Fatalf("no provider called %q", which)
	}
	provider := &counting{Provider: build(os.Getenv("REVIEW_MODEL"))}

	var scores []score
	for _, c := range evalSet() {
		if *evalCases != "" && !strings.Contains(c.Name, *evalCases) {
			continue
		}
		t.Run(c.Name, func(t *testing.T) {
			scores = append(scores, runCase(t, c, provider))
		})
	}
	t.Cleanup(func() {
		board := scoreboard(scores, *evalRuns)
		t.Log("\n" + board)
		fmt.Printf("\n%s\nasked %s %d times for $%.4f\n", board, provider.Name(), provider.asks, provider.cost)
	})
}

func runCase(t *testing.T, c evalCase, provider Provider) score {
	root := c.Corpus(t)
	change, err := Gather(c.Rev, root)
	if err != nil {
		t.Fatal(err)
	}
	jobs, err := chosen(c.Jobs)
	if err != nil {
		t.Fatal(err)
	}
	s := score{Name: c.Name}
	for _, w := range c.Want {
		s.Found = append(s.Found, tally{Subject: w.String()})
	}
	for _, w := range c.Silent {
		s.Noise = append(s.Noise, tally{Subject: w.String()})
	}
	for range *evalRuns {
		result := Reviewer{Provider: provider}.Run(context.Background(), change, jobs)
		for _, err := range result.Failures {
			t.Errorf("job failed: %v", err)
			s.Failures++
		}
		for i, w := range c.Want {
			if raised(w, result.Findings) {
				s.Found[i].Count++
			}
		}
		for i, w := range c.Silent {
			if raised(w, result.Findings) {
				s.Noise[i].Count++
			}
		}
		if c.Most > 0 && len(result.Findings) > c.Most {
			s.Most = max(s.Most, len(result.Findings))
		}
		if *evalShow {
			for _, f := range result.Findings {
				t.Logf("  %s", strings.ReplaceAll(f.String(), "\n", " "))
			}
			if len(result.Findings) == 0 {
				t.Log("  (nothing reported)")
			}
		}
	}
	for _, found := range s.Found {
		if found.Count < *evalRuns {
			t.Errorf("missed %s in %d of %d runs", found.Subject, *evalRuns-found.Count, *evalRuns)
		}
	}
	for _, noise := range s.Noise {
		if noise.Count > 0 {
			t.Errorf("raised %s in %d of %d runs, which is true but unwanted", noise.Subject, noise.Count, *evalRuns)
		}
	}
	if s.Most > 0 {
		t.Errorf("reported %d findings at most, where %d is the whole right answer", s.Most, c.Most)
	}
	return s
}

func raised(w want, findings []Finding) bool {
	for _, f := range findings {
		if w.matches(f) {
			return true
		}
	}
	return false
}

// scoreboard lays the results out so that a change to the criteria can be
// read as a movement rather than a verdict.
func scoreboard(scores []score, runs int) string {
	var b strings.Builder
	var found, wanted, noise int
	fmt.Fprintf(&b, "eval over %d run(s) per case\n", runs)
	for _, s := range scores {
		fmt.Fprintf(&b, "\n%s\n", s.Name)
		for _, t := range s.Found {
			label := "found"
			if t.Count < runs {
				label = "MISS "
			}
			fmt.Fprintf(&b, "  %s  %d/%d  %s\n", label, t.Count, runs, t.Subject)
			found += t.Count
			wanted += runs
		}
		for _, t := range s.Noise {
			label := "quiet"
			if t.Count > 0 {
				label = "NOISE"
			}
			fmt.Fprintf(&b, "  %s  %d/%d  %s\n", label, t.Count, runs, t.Subject)
			noise += t.Count
		}
		if s.Most > 0 {
			fmt.Fprintf(&b, "  LOUD   reported as many as %d findings\n", s.Most)
			noise++
		}
		if s.Failures > 0 {
			fmt.Fprintf(&b, "  failed %d time(s)\n", s.Failures)
		}
	}
	fmt.Fprintf(&b, "\nfound %d of %d wanted, %d unwanted\n", found, wanted, noise)
	return b.String()
}
