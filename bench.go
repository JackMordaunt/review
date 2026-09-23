package main

// The deterministic checks cost nothing to run, so their precision can be
// measured over as much history as there is: run them over the last N
// commits and count what fires. A rule that fires on a tenth of ordinary
// commits is not measuring what it claims to.

import (
	"flag"
	"fmt"
	"os"
	"slices"
	"strings"
)

// bench runs the deterministic checks over a repository's recent commits
// and prints the fire rate per rule. -author narrows the commits to an
// author's, which is how the checks are held against the population they
// exist for.
func bench(args []string) error {
	flags := flag.NewFlagSet("bench", flag.ContinueOnError)
	n := flags.Int("n", 200, "How many recent commits to measure.")
	author := flags.String("author", "", "Only commits whose author matches this pattern, as git log --author takes it.")
	rule := flags.String("rule", "", "List the commits one rule fired on, with their subjects.")
	if err := flags.Parse(args); err != nil {
		return err
	}
	root := flags.Arg(0)
	if root == "" {
		var err error
		if root, err = repository(); err != nil {
			return err
		}
	}
	listing := []string{"rev-list", "--no-merges", fmt.Sprintf("-%d", *n)}
	if *author != "" {
		listing = append(listing, "--author="+*author)
	}
	listing = append(listing, "HEAD")
	out, err := git(root, listing...)
	if err != nil {
		return err
	}
	var commits []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			commits = append(commits, line)
		}
	}
	if len(commits) == 0 {
		return fmt.Errorf("no commits to measure")
	}

	type fire struct {
		commit, subject, message string
	}
	fires := map[string][]fire{}
	measured := 0
	for i, commit := range commits {
		fmt.Fprintf(os.Stderr, "\r  %d of %d", i+1, len(commits))
		change, err := Gather(commit+"^.."+commit, root)
		if err != nil {
			continue // A root commit has no parent to diff against.
		}
		measured++
		findings := runChecks(change)
		seen := map[string]bool{}
		for _, f := range findings {
			if seen[f.Rule] {
				continue
			}
			seen[f.Rule] = true
			subject := strings.SplitN(strings.TrimSpace(change.Message), "\n", 2)[0]
			fires[f.Rule] = append(fires[f.Rule], fire{commit[:8], subject, f.Message})
		}
		closeTrees() // One tree per commit; a bench must not keep them all.
	}
	fmt.Fprint(os.Stderr, "\r                \r")

	if *rule != "" {
		for _, f := range fires[*rule] {
			fmt.Printf("%s  %s\n    %s\n", f.commit, f.subject, first(f.message, 160))
		}
		fmt.Printf("\n%s fired on %d of %d commits\n", *rule, len(fires[*rule]), measured)
		return nil
	}
	rules := make([]string, 0, len(fires))
	for r := range fires {
		rules = append(rules, r)
	}
	slices.SortFunc(rules, func(a, b string) int {
		if c := len(fires[b]) - len(fires[a]); c != 0 {
			return c
		}
		return strings.Compare(a, b)
	})
	fmt.Printf("%d commits measured\n\n", measured)
	fmt.Printf("%-28s %6s  %s\n", "rule", "fires", "rate")
	for _, r := range rules {
		fmt.Printf("%-28s %6d  %4.1f%%\n", r, len(fires[r]), 100*float64(len(fires[r]))/float64(measured))
	}
	if len(rules) == 0 {
		fmt.Println("nothing fired")
	}
	return nil
}
