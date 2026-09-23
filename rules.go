package main

// The rules are what an agent is handed. A finding cites one by id, and the
// id has to lead somewhere: the criteria a job judges against, or the
// description of the deterministic check that measured it. Printing them
// from the binary is what makes the rules travel with it.

import (
	"cmp"
	"flag"
	"fmt"
	"maps"
	"slices"
	"strings"
)

// staticRule describes one deterministic check, for the reader who met its
// id in a finding.
type staticRule struct {
	ID          string
	Description string
}

// staticRules are the deterministic checks, in the order the readme lists
// them. Each id here is one a finding can carry with Job "static".
var staticRules = []staticRule{
	{"go-build", "the Go compiler cannot build a package the change touched; must-fix wherever the error lands"},
	{"go-vet/<analyzer>", "go vet's finding, on a line the change adds — with review-vet's extra analysers where it is installed; nilness and vet's own set are must-fix, shadow and unusedwrite consider, modernize note"},
	{"staticcheck/<code>", "the Go analyser's finding, on a line the change adds; SA is must-fix, S and U consider, the rest note"},
	{"odin-check", "odin check -vet -strict-style cannot check a package the change touched: a type error is must-fix wherever it lands, a vet failure consider, a style failure note"},
	{"tsc/<code>", "the TypeScript compiler's error under the project's own tsconfig; must-fix wherever it lands; working tree only"},
	{"ruff/<code>", "ruff's finding on a line the change adds; pyflakes codes consider, style codes note"},
	{"mypy/<code>", "mypy's type error on a line the change adds, missing imports ignored; working tree only"},
	{"cargo/<code>", "cargo check's — or clippy's — diagnostic: an error is must-fix wherever it lands, a warning consider on a line the change adds"},
	{"semgrep/<rule>", "a semgrep match on a line the change adds, under the repository's own .semgrep.yml or the registry's p/default pack; the rule's severity is kept: ERROR must-fix, WARNING consider, INFO note"},
	{"message-low-entropy", "the commit message's Shannon entropy is under 3.2 bits per byte: a phrase repeated rather than a description"},
	{"message-boilerplate", "the commit message keeps under 20% of its length after zlib: a block of text pasted or repeated whole"},
	{"message-common-words", "the commit message is made only of the repository's commonest commit words and names nothing the change touches"},
	{"message-frustration", "the commit message is an exclamation — oops, whoops, damn — where a description should be"},
	{"message-not-imperative", "the subject's first word after its package prefix is past tense, a gerund, or the author"},
	{"message-no-body", "a change over 50 lines carries no body, and the diff does not only move text around"},
	{"message-long-body", "the body is over 150 words, listing what the diff already shows"},
	{"history-coupled-file", "history ties a changed file to a partner the change does not touch: Jaccard at least 0.7 over at least 5 shared commits"},
	{"message-names-unknown", "the commit message names an identifier, path or call that is in neither the diff nor the repository at the end of the change"},
	{"formatting-mixed-in", "half or more of the change's lines change only whitespace, and at least 10 change something else: a reformatting with logic in it"},
	{"suppression-added", "the change adds its own review:ignore dismissal, before the readers have run"},
	{"test-deleted", "the change deletes a test function that no added test renames"},
	{"no-stutter", "an exported name's first word is its package: ico.IcoEntry says ico twice"},
	{"no-shadow", "a new name is a predeclared identifier, a standard library package, or a runtime global"},
	{"abbreviation", "a new name carries an invented abbreviation: cfg, mgr, hdlr, svc, btn, cnt"},
	{"test-no-assertion", "an added or altered test has no call that could fail it; it can only fail by crashing"},
	{"assertion-always-true", "an assertion in an added or altered test holds whatever the code does: a literal true, two literals, or a value against itself"},
	{"duplicate-body", "a new function's body already exists, token for token (must-fix) or in shape with every name changed (consider)"},
	{"function-too-long", "a new function is over 150 lines; 95% of measured functions fit in 109"},
	{"nesting-too-deep", "a new function nests blocks more than 5 deep; 99% of measured functions stay within 6"},
	{"comment-restates-code", "every content word of an added comment is in the line of code below it"},
	{"todo-without-reference", "an added TODO, FIXME, XXX or HACK names no issue, ticket, link or person"},
	{"commented-out-code", "an added comment run holds code: two statement-shaped lines, or one beyond doubt"},
	{"debug-leftover", "an added line is a debugger statement, a breakpoint, dbg!, spew.Dump, console.log, or a DEBUG print"},
	{"error-swallowed", "an added line drops an error: _ = err, an empty catch, an except that passes"},
	{"new-symbol-unreferenced", "nothing in the repository refers to a new declaration but its own line"},
	{"code-without-tests", "the change adds 50 or more lines of code, touches no test, and the repository keeps tests"},
}

// Every rule above is one Checks() can report; the list is what review rules
// prints, and the test that every reported rule is described keeps the two
// in step.

// printRules prints the criteria for a job, the description of a rule, or
// everything, so that an agent given a finding can read what it was judged
// against without leaving the terminal. With -dismissed it prints instead
// how often each rule is dismissed in the working tree: a rule dismissed
// everywhere is a rule to rewrite.
func printRules(args []string) error {
	flags := flag.NewFlagSet("rules", flag.ContinueOnError)
	dismissed := flags.Bool("dismissed", false, "Count the review:ignore dismissals in the tree, per rule.")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *dismissed {
		return printDismissals()
	}
	which := flags.Arg(0)
	if which == "" {
		fmt.Print("# Deterministic checks\n\n")
		for _, r := range staticRules {
			fmt.Printf("- `%s` — %s\n", r.ID, r.Description)
		}
		for _, job := range Jobs() {
			fmt.Printf("\n%s", job.Criteria)
		}
		return nil
	}
	for _, job := range Jobs() {
		if job.Name == which {
			fmt.Print(job.Criteria)
			return nil
		}
	}
	if job, text, ok := criterion(which); ok {
		fmt.Printf("%s, from the %s criteria:\n\n%s\n", which, job, text)
		return nil
	}
	family, _, _ := strings.Cut(which, "/")
	for _, r := range staticRules {
		if r.ID == which || (strings.Contains(which, "/") && strings.HasPrefix(r.ID, family+"/")) {
			fmt.Printf("%s, a deterministic check:\n\n%s\n", which, r.Description)
			return nil
		}
	}
	names := make([]string, 0, len(Jobs()))
	for _, job := range Jobs() {
		names = append(names, job.Name)
	}
	slices.Sort(names)
	return fmt.Errorf("no job or rule called %q; the jobs are %s", which, strings.Join(names, ", "))
}

// printDismissals counts the dismissals in the working tree per rule, with
// where each is and why, so that the rules people argue with are visible.
func printDismissals() error {
	root, err := repository()
	if err != nil {
		return err
	}
	tree, err := treeAt(root, "")
	if err != nil {
		return err
	}
	sources, err := tree.Sources()
	if err != nil {
		return err
	}
	type spot struct {
		where, why string
	}
	byRule := map[string][]spot{}
	for _, file := range slices.Sorted(maps.Keys(sources)) {
		if !isCodeFile(file) {
			continue
		}
		for i, line := range strings.Split(string(sources[file]), "\n") {
			m := ignore.FindStringSubmatch(line)
			if m == nil || !ruleID.MatchString(m[1]) {
				continue
			}
			// A dismissal quoted inside a string literal, as a test's
			// fixture is, ends where the literal's line does.
			why := strings.TrimSpace(strings.SplitN(m[2], `\n`, 2)[0])
			why = strings.TrimSpace(strings.TrimSuffix(why, `"`))
			if why == "" {
				why = "no reason given"
			}
			byRule[m[1]] = append(byRule[m[1]], spot{fmt.Sprintf("%s:%d", file, i+1), why})
		}
	}
	if len(byRule) == 0 {
		fmt.Println("no dismissals in the tree")
		return nil
	}
	rules := slices.SortedFunc(maps.Keys(byRule), func(a, b string) int {
		if c := cmp.Compare(len(byRule[b]), len(byRule[a])); c != 0 {
			return c
		}
		return cmp.Compare(a, b)
	})
	for _, rule := range rules {
		spots := byRule[rule]
		fmt.Printf("%-28s %d\n", rule, len(spots))
		for _, s := range spots {
			fmt.Printf("    %s  %s\n", s.where, s.why)
		}
	}
	return nil
}

// criterion finds the bullet that defines a rule, in whichever job's
// criteria holds it, with the lines that continue it.
func criterion(id string) (job, text string, ok bool) {
	marker := "- `" + id + "`"
	for _, j := range Jobs() {
		lines := strings.Split(j.Criteria, "\n")
		for i, line := range lines {
			if !strings.HasPrefix(line, marker) {
				continue
			}
			var kept []string
			for _, l := range lines[i:] {
				if len(kept) > 0 && !strings.HasPrefix(l, "  ") {
					break
				}
				kept = append(kept, l)
			}
			return j.Name, strings.Join(kept, "\n"), true
		}
	}
	return "", "", false
}
