// Command review reads a change the way several narrow readers would, and
// reports what they noticed.
//
// It is advisory. It never fails a build and never blocks a commit: the
// deterministic checks a repository already runs are what should do that. This
// looks at the things those checks cannot — whether a name says what the thing
// is, whether a fact is already stated elsewhere, whether a test can fail,
// whether a comment claims something nobody verified.
//
//	review                 the staged change
//	review HEAD^           the last commit
//	review --json          for a program rather than a person
//
// A finding is dismissed where it is wrong, in the source it concerns:
//
//	//review:ignore <rule> <why>
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "review:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		asJSON  bool
		verbose bool
		show    bool
		only    string
	)
	flag.BoolVar(&asJSON, "json", false, "Report findings as JSON, for an agent rather than a person.")
	flag.BoolVar(&verbose, "verbose", false, "Show what each job read and what it cost.")
	flag.BoolVar(&show, "show", false, "Print what each job would be sent and stop, without asking anything.")
	flag.StringVar(&only, "jobs", "", "Run only these jobs, comma separated.")
	flag.Usage = usage
	flag.Parse()

	root, err := repository()
	if err != nil {
		return err
	}
	change, err := Gather(flag.Arg(0), root)
	if err != nil {
		return err
	}
	if strings.TrimSpace(change.Diff) == "" {
		if !asJSON {
			fmt.Println("nothing to review")
		} else {
			fmt.Println(`{"findings":[]}`)
		}
		return nil
	}

	jobs, err := chosen(only)
	if err != nil {
		return err
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
		return nil
	}
	if verbose {
		fmt.Printf("reviewing %d files, %d new names, %d tests, %d comments\n",
			len(change.Files), len(change.Symbols), len(change.Tests), len(change.Comments))
	}

	reviewer := Reviewer{Client: anthropic.NewClient(), Verbose: verbose}
	findings, failures := reviewer.Run(context.Background(), change, jobs)

	kept, dismissed := filter(root, findings)
	Sort(kept)

	if asJSON {
		return report(kept)
	}
	render(kept, dismissed, failures, verbose)
	return nil
}

// filter drops the findings the source itself dismisses, and counts them so a
// silent dismissal is still visible.
func filter(root string, findings []Finding) (kept []Finding, dismissed int) {
	if err := os.Chdir(root); err != nil {
		return findings, 0
	}
	for _, f := range findings {
		if _, ok := Suppressed(f); ok {
			dismissed++
			continue
		}
		kept = append(kept, f)
	}
	return kept, dismissed
}

func render(findings []Finding, dismissed int, failures []error, verbose bool) {
	for _, err := range failures {
		fmt.Fprintln(os.Stderr, "  job failed:", err)
	}
	if len(findings) == 0 {
		fmt.Print("no findings")
		if dismissed > 0 {
			fmt.Printf(" (%d dismissed in the source)", dismissed)
		}
		fmt.Println()
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
	if dismissed > 0 {
		fmt.Printf(", %d dismissed in the source", dismissed)
	}
	fmt.Println()
	if verbose {
		fmt.Println("\nDismiss a finding where it is wrong, in the source it concerns:")
		fmt.Println("  //review:ignore <rule> <why>")
	}
}

func indent(s string) string {
	return strings.ReplaceAll(s, "\n      ", "\n    ")
}

func report(findings []Finding) error {
	if findings == nil {
		findings = []Finding{}
	}
	for i := range findings {
		findings[i].SeverityName = findings[i].Severity.String()
	}
	out, err := json.MarshalIndent(map[string]any{"findings": findings}, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
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

With no revision the staged change is read. A revision is anything git diff
takes, such as HEAD^ for the last commit.

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

Dismiss a finding where it is wrong, in the source it concerns:
  //review:ignore <rule> <why>
`)
}
