// Command review reads a change the way several narrow readers would, and
// reports what they noticed.
//
// It is advisory. It never fails a build and never blocks a commit: the
// deterministic checks a repository already runs are what should do that. This
// looks at the things those checks cannot — whether a name says what the thing
// is, whether a fact is already stated elsewhere, whether a test can fail,
// whether a comment claims something nobody verified. A set of deterministic
// checks — the commit message, the repository's history, and staticcheck where
// it is installed — run before anything is asked. Each job's findings are put
// back to the provider once, against the same evidence, and the ones a second
// reading does not let stand are retracted rather than reported; what each ask
// answered is cached, so that a re-run of an unchanged part of the change
// replays it rather than asking again.
//
//	review                 the staged change
//	review HEAD^..HEAD     the last commit
//	review --json          for a program rather than a person
//	review rules <id>      what a finding was judged against
//
// A finding is dismissed where it is wrong, in the source it concerns:
//
//	//review:ignore <rule> <why>
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
)

func main() {
	err := run()
	if errors.Is(err, errMustFix) {
		// The report has already said which finding; the exit code is the
		// whole of what a hook reads.
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "review:", err)
		os.Exit(1)
	}
}

// errMustFix is the refusal --exit-code asks for. It is returned rather than
// exited on, so that the deferred cleanup and the cache's save still run.
var errMustFix = errors.New("a must-fix finding stands")

func run() error {
	var (
		asJSON      bool
		verbose     bool
		show        bool
		only        string
		which       string
		model       string
		noVerify    bool
		fresh       bool
		messageFile string
		exitCode    bool
		baseline    string
	)
	flag.BoolVar(&asJSON, "json", false, "Report findings as JSON, for an agent rather than a person.")
	flag.StringVar(&messageFile, "message-file", "", "Read the commit message from this file, as a commit-msg hook is given it; a staged change has no message otherwise.")
	flag.BoolVar(&exitCode, "exit-code", false, "Exit 1 when a must-fix finding stands, so a hook can refuse the change.")
	flag.StringVar(&baseline, "baseline", "", "A previous --json report; each finding is then reported as new, persisting or resolved against it.")
	flag.BoolVar(&verbose, "verbose", false, "Show what each job read and what it cost.")
	flag.BoolVar(&show, "show", false, "Print what each job would be sent and stop, without asking anything.")
	flag.BoolVar(&noVerify, "no-verify", false, "Skip the second reading that checks what each job reported.")
	flag.BoolVar(&fresh, "fresh", false, "Ask the provider even where the answer cache holds this exact question.")
	flag.StringVar(&only, "jobs", "", "Run only these jobs, comma separated.")
	flag.StringVar(&which, "provider", orElse(os.Getenv("REVIEW_PROVIDER"), "chain"), "Who answers: chain (probe the default order), claude, pi, api, or command.")
	flag.StringVar(&model, "model", os.Getenv("REVIEW_MODEL"), "Which model, in whatever form the provider names them.")
	flag.Usage = usage
	flag.Parse()
	defer closeTrees()

	switch flag.Arg(0) {
	case "rules":
		return printRules(flag.Args()[1:])
	case "bench":
		return bench(flag.Args()[1:])
	case "hook":
		return hook(flag.Args()[1:])
	case "agent":
		return agent()
	}

	root, err := repository()
	if err != nil {
		return err
	}
	change, err := Gather(flag.Arg(0), root)
	if err != nil {
		return err
	}
	if messageFile != "" {
		if change.Message, err = readMessage(messageFile); err != nil {
			return err
		}
	}
	if strings.TrimSpace(change.Diff) == "" {
		if asJSON {
			return report(contract{Version: contractVersion, Status: "empty"})
		}
		fmt.Println("nothing to review")
		return nil
	}

	jobs, err := chosen(only)
	if err != nil {
		return err
	}
	// The deterministic checks ask nothing of a provider, so they run before
	// one is built and survive a model that cannot answer.
	static := runChecks(change)
	static = append(static, checkAnalysers(root, flag.Arg(0), change, Analysers()...)...)
	for i := range static {
		// The deterministic checks are their own verification: what they
		// report was measured, not read once.
		static[i].Verified = true
	}

	if show {
		for _, job := range jobs {
			subject := job.Subject(change)
			fmt.Printf("=== %s ===\n", job.Name)
			if strings.TrimSpace(subject) == "" {
				fmt.Print("(nothing to read)\n\n")
				continue
			}
			fmt.Printf("%s\n", subject)
		}
		// What the deterministic side found costs nothing to show, and it
		// is what a reader of the packets is about to act on anyway.
		fmt.Println("=== static ===")
		kept, _ := filter(root, static)
		Sort(kept)
		if len(kept) == 0 {
			fmt.Println("(no findings)")
		}
		for _, f := range kept {
			fmt.Printf("  %s\n", indent(f.String()))
		}
		return nil
	}
	if verbose {
		fmt.Printf("reviewing %d files, %d new names, %d tests, %d comments\n",
			len(change.Files), len(change.Symbols), len(change.Tests), len(change.Comments))
	}

	var provider Provider
	var providerName string
	if which == "chain" {
		picked, name, err := defaultChain().pick(context.Background(), func(s string) { fmt.Fprintln(os.Stderr, s) })
		if err != nil {
			return err
		}
		provider = picked
		providerName = provider.Name()
		if verbose {
			fmt.Printf("asking %s\n", name)
		}
	} else {
		build, known := Providers()[which]
		if !known {
			return fmt.Errorf("no provider called %q", which)
		}
		provider = build(model)
		providerName = provider.Name()
		if verbose {
			fmt.Printf("asking %s\n", providerName)
		}
	}

	// The cache records what each ask answered, so that a re-run of a part
	// of the change that did not change replays it instead of asking. A
	// cache that cannot exist is no fault of the review.
	cache := openCache(fresh)
	if cache != nil {
		defer cache.save()
	}
	reviewer := Reviewer{Provider: provider, Verbose: verbose, Verify: !noVerify, Cache: cache}
	result := reviewer.Run(context.Background(), change, jobs)

	findings := append(result.Findings, static...)
	kept, dismissed := filter(root, findings)
	Sort(kept)
	nameFindings(kept)
	if tree, treeErr := treeAt(root, flag.Arg(0)); treeErr == nil {
		for i := range kept {
			if kept[i].File != "" && kept[i].Line > 0 {
				kept[i].Snippet = tree.Line(kept[i].File, kept[i].Line)
			}
		}
	}
	var against *Baseline
	if baseline != "" {
		against, err = compare(baseline, kept)
		if err != nil {
			return err
		}
	}

	env := contract{
		Version:   contractVersion,
		Status:    statusOf(change, result),
		Provider:  providerName,
		Findings:  kept,
		Retracted: result.Retracted,
		Failed:    faults(result.Failures),
		Skipped:   result.Skipped,
		Uncovered: change.Uncovered,
		Dismissed: dismissed,
		Truncated: change.Truncated,
		Baseline:  against,
		Usage: metered{
			In: result.In, Out: result.Out, Cached: result.Cached,
			Replayed: result.Replayed, Cost: result.Cost,
		},
	}
	if asJSON {
		if err := report(env); err != nil {
			return err
		}
	} else {
		render(env, result.Failures, verbose)
	}
	// The review is advisory unless asked to gate: then a must-fix finding
	// that stands is the one thing it refuses, and the report above says
	// which.
	if exitCode && mustFix(kept) {
		return errMustFix
	}
	return nil
}

// mustFix is whether any finding is one the review would refuse on.
func mustFix(findings []Finding) bool {
	for _, f := range findings {
		if f.Severity == MustFix {
			return true
		}
	}
	return false
}

// readMessage reads a commit message the way git will: the lines its
// comment character opens are the template's, not the author's, and a
// message file a hook is given is full of them.
func readMessage(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading the message: %w", err)
	}
	var kept []string
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.TrimSpace(strings.Join(kept, "\n")), nil
}

// contractVersion is the shape of the JSON report, so that a program
// reading it can tell when the shape moves under it.
const contractVersion = 1

// JobFault is one job that could not finish, and what failed about it.
type JobFault struct {
	Job   string `json:"job"`
	Error string `json:"error"`
}

// metered is what the asks cost, in tokens and dollars. Answers replayed
// from the cache count as replayed rather than as usage: they cost nothing
// this run.
type metered struct {
	In       int     `json:"in"`
	Out      int     `json:"out"`
	Cached   int     `json:"cached"`
	Replayed int     `json:"replayed"`
	Cost     float64 `json:"usd"`
}

// contract is the whole report a program reads: what was found, what the
// second reading did not let stand, what was dismissed in the source, and
// how complete the measurement was. The status is what makes an empty
// findings list readable: "complete" is the only status an empty list can
// be read as a pass against, because the others say which part of the
// measurement is missing.
type contract struct {
	Version   int         `json:"version"`
	Status    string      `json:"status"`
	Provider  string      `json:"provider,omitempty"`
	Findings  []Finding   `json:"findings"`
	Retracted []Retracted `json:"retracted"`
	Failed    []JobFault  `json:"failed"`
	Skipped   []string    `json:"skipped"`
	Uncovered []Gap       `json:"uncovered"`
	Dismissed []Dismissed `json:"dismissed"`
	Truncated bool        `json:"truncated,omitempty"`
	// Baseline is how this run's findings stand against a previous run's,
	// when one was given: the answer to "did the fix take".
	Baseline *Baseline `json:"baseline,omitempty"`
	Usage    metered   `json:"usage"`
}

// Baseline is this run's findings named against a previous report's, by
// id. A loop reads resolved to know its fixes took, persisting to know what
// is left, and new to know what the fixes cost.
type Baseline struct {
	From       string   `json:"from"`
	Resolved   []string `json:"resolved"`
	Persisting []string `json:"persisting"`
	New        []string `json:"new"`
}

// compare reads the findings of a previous report and names this run's
// against them. Only the report's standing findings count: a finding it
// retracted or dismissed was not one to fix.
func compare(path string, now []Finding) (*Baseline, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading the baseline: %w", err)
	}
	var previous struct {
		Findings []struct {
			ID string `json:"id"`
		} `json:"findings"`
	}
	if err := json.Unmarshal(data, &previous); err != nil {
		return nil, fmt.Errorf("the baseline is not a review report: %w", err)
	}
	before := map[string]bool{}
	for _, f := range previous.Findings {
		if f.ID != "" {
			before[f.ID] = true
		}
	}
	b := &Baseline{From: path, Resolved: []string{}, Persisting: []string{}, New: []string{}}
	seen := map[string]bool{}
	for _, f := range now {
		seen[f.ID] = true
		if before[f.ID] {
			b.Persisting = append(b.Persisting, f.ID)
		} else {
			b.New = append(b.New, f.ID)
		}
	}
	for id := range before {
		if !seen[id] {
			b.Resolved = append(b.Resolved, id)
		}
	}
	slices.Sort(b.Resolved)
	return b, nil
}

// statusOf names how complete the measurement was. The parts of the change
// the deterministic side could not read and the jobs that failed are what
// keep an empty findings list from being read as a pass.
func statusOf(change *Change, result RunResult) string {
	if len(result.Failures) > 0 || len(change.Uncovered) > 0 || change.Truncated {
		return "incomplete"
	}
	return "complete"
}

// faults pairs each failure's job with what failed about it, for the
// report.
func faults(failures []error) []JobFault {
	var out []JobFault
	for _, err := range failures {
		job, cause, found := strings.Cut(err.Error(), ": ")
		if !found {
			out = append(out, JobFault{Job: err.Error(), Error: err.Error()})
			continue
		}
		out = append(out, JobFault{Job: job, Error: cause})
	}
	return out
}

// Dismissed is a finding the source itself answered, and the answer.
type Dismissed struct {
	Finding Finding `json:"finding"`
	Why     string  `json:"why"`
}

// filter drops the findings the source itself dismisses, and keeps them so
// that a silent dismissal can still be read back.
func filter(root string, findings []Finding) (kept []Finding, dismissed []Dismissed) {
	if err := os.Chdir(root); err != nil {
		return findings, nil
	}
	for _, f := range findings {
		if why, ok := Suppressed(f); ok {
			dismissed = append(dismissed, Dismissed{Finding: f, Why: why})
			continue
		}
		kept = append(kept, f)
	}
	return kept, dismissed
}

func render(env contract, failures []error, verbose bool) {
	for _, err := range failures {
		fmt.Fprintln(os.Stderr, "  job failed:", err)
	}
	// A dismissal reaches a few lines either side of itself, so which
	// findings one answered is worth being able to read; a retraction is
	// worth reading in full, because it is the second reading's word
	// against the first's.
	if verbose {
		for _, d := range env.Dismissed {
			fmt.Printf("  dismissed: %s:%d %s (%s)\n", d.Finding.File, d.Finding.Line, d.Finding.Rule, d.Why)
		}
		for _, r := range env.Retracted {
			fmt.Printf("  retracted: [%s] %s:%d — %s\n", r.Finding.Rule, r.Finding.File, r.Finding.Line, first(r.Reason, 120))
		}
	}
	findings := env.Findings
	if len(findings) == 0 {
		fmt.Print("no findings")
		if len(env.Dismissed) > 0 {
			fmt.Printf(" (%d dismissed in the source)", len(env.Dismissed))
		}
		fmt.Println()
		retractedNote(env)
		baselineNote(env)
		return
	}
	var severity Severity = -1
	for _, f := range findings {
		if f.Severity != severity {
			severity = f.Severity
			fmt.Printf("\n%s\n", strings.ToUpper(severity.String()))
		}
		fmt.Printf("  %s\n", indent(f.String()))
	}
	fmt.Printf("\n%d findings", len(findings))
	if len(env.Dismissed) > 0 {
		fmt.Printf(", %d dismissed in the source", len(env.Dismissed))
	}
	fmt.Println()
	retractedNote(env)
	baselineNote(env)
	if verbose {
		fmt.Println("\nDismiss a finding where it is wrong, in the source it concerns:")
		fmt.Println("  //review:ignore <rule> <why>")
	}
}

// baselineNote says how the findings stand against the previous report,
// where one was given.
func baselineNote(env contract) {
	if env.Baseline == nil {
		return
	}
	b := env.Baseline
	fmt.Printf("against %s: %d resolved, %d persisting, %d new\n", b.From, len(b.Resolved), len(b.Persisting), len(b.New))
	if len(b.Persisting) > 0 {
		fmt.Printf("  persisting: %s\n", strings.Join(b.Persisting, ", "))
	}
}

// retractedNote says how many findings did not survive the second reading,
// because a retraction that went unmentioned would read as the first
// reading having been right all along.
func retractedNote(env contract) {
	if len(env.Retracted) == 0 {
		return
	}
	fmt.Printf("%d of the findings reported did not survive verification\n", len(env.Retracted))
}

func indent(s string) string {
	return strings.ReplaceAll(s, "\n      ", "\n    ")
}

// report prints the contract: the whole measurement, not only the
// findings, so that a program reading it can tell a pass from a hole. Each
// finding is given its stable id and its severity as text, which is what a
// loop needs to answer a finding and check it stayed answered.
func report(env contract) error {
	// Every list is said even when empty: a key an agent cannot find is a
	// hole it guesses about, and the contract is what makes the reading
	// readable without guessing.
	if env.Findings == nil {
		env.Findings = []Finding{}
	}
	if env.Retracted == nil {
		env.Retracted = []Retracted{}
	}
	if env.Failed == nil {
		env.Failed = []JobFault{}
	}
	if env.Skipped == nil {
		env.Skipped = []string{}
	}
	if env.Uncovered == nil {
		env.Uncovered = []Gap{}
	}
	if env.Dismissed == nil {
		env.Dismissed = []Dismissed{}
	}
	nameFindings(env.Findings)
	retracted := make([]Finding, len(env.Retracted))
	for i := range env.Retracted {
		retracted[i] = env.Retracted[i].Finding
	}
	nameFindings(retracted)
	for i := range env.Retracted {
		env.Retracted[i].Finding = retracted[i]
	}
	dismissed := make([]Finding, len(env.Dismissed))
	for i := range env.Dismissed {
		dismissed[i] = env.Dismissed[i].Finding
	}
	nameFindings(dismissed)
	for i := range env.Dismissed {
		env.Dismissed[i].Finding = dismissed[i]
	}
	out, err := json.MarshalIndent(env, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

// nameFindings fills in what a finding carries only in the report: its
// severity as text, and the id that names it across runs. Two findings
// that hash the same — one rule, one file, two comments — are told apart
// by a counter, in the order they are listed.
func nameFindings(findings []Finding) {
	seen := map[string]int{}
	for i := range findings {
		findings[i].SeverityName = findings[i].Severity.String()
		identify(&findings[i])
		seen[findings[i].ID]++
		if n := seen[findings[i].ID]; n > 1 {
			findings[i].ID = fmt.Sprintf("%s-%d", findings[i].ID, n)
		}
	}
}

func chosen(only string) ([]Job, error) {
	all := Jobs()
	if only == "" {
		return all, nil
	}
	var out []Job
	for _, name := range strings.Split(only, ",") {
		name = strings.TrimSpace(name)
		found := false
		for _, job := range all {
			if job.Name == name {
				out = append(out, job)
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("no job called %q", name)
		}
	}
	return out, nil
}

func repository() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not inside a git repository")
	}
	return strings.TrimSpace(string(out)), nil
}

func usage() {
	fmt.Fprint(flag.CommandLine.Output(), `review reads a change the way several narrow readers would.

Usage:
  review [flags] [revision]
  review rules [job | rule]

With no revision the staged change is read, which has no commit message
unless --message-file names one. A revision is anything git diff takes,
such as HEAD^..HEAD for the last commit. "rules" prints what a finding
was judged against: every rule, one job's criteria, or one rule.

Flags:
`)
	flag.PrintDefaults()
	fmt.Fprint(flag.CommandLine.Output(), `
Jobs:
  duplication  whether the change states something the repository already states
  tests        whether the tests it adds can fail
  namer        whether the names it adds say what the things are
  claims       whether the comments it adds assert what nobody checked
  hygiene      whether the commit message matches the commit

Before the jobs run, and without a model, the deterministic checks measure
the commit message, the history, the review's own mechanisms, and the code
the change adds: its names, tests, bodies, comments and leftovers. Run
"review rules" for the list.

Dismiss a finding where it is wrong, in the source it concerns:
  //review:ignore <rule> <why>
`)
}
