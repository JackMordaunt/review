package main

// staticcheck is the repository's own Go analyser, and review has nothing to
// teach it about Go. The check below only decides which of its findings
// belong to the change: staticcheck is free to say what it likes about the
// rest of the repository, and review's contract is the change, so a finding
// is kept only when it lands on a line the change adds.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// staticcheckTimeout bounds one run. A cold first analysis of a large module
// can take minutes; past this the check says nothing rather than holding the
// review, and the run warms the build cache for the next one.
const staticcheckTimeout = 5 * time.Minute

// checkCode matches a staticcheck finding code, such as SA4006 or S1002.
// Anything else staticcheck emits — compile errors, for instance — is not a
// finding about the code.
var checkCode = regexp.MustCompile(`^[A-Z]+[0-9]+$`)

// checkStaticcheck runs staticcheck over the packages the change touches and
// reports what it found on the lines the change adds. It is called beside
// the other deterministic checks, so its findings survive a model that
// cannot answer. It says nothing where it has nothing to say: without the
// binary, without Go files, or without a module to analyse.
func checkStaticcheck(root, rev string, c *Change) []Finding {
	if !touchesGo(c) {
		return nil
	}
	if _, err := exec.LookPath("staticcheck"); err != nil {
		return nil
	}
	tree := root
	after, ranged := ends(rev)
	if ranged {
		// The change arrived at a tree the working directory may have left
		// behind long ago, so the analysis runs on that tree, materialised
		// to a scratch directory the way the other frontends do.
		tmp, err := os.MkdirTemp("", "review-staticcheck-")
		if err != nil {
			noteStaticcheck("cannot make a scratch directory: %v", err)
			return nil
		}
		defer os.RemoveAll(tmp)
		archive := filepath.Join(tmp, "tree.tar")
		if _, err := git(root, "archive", "-o", archive, after); err != nil {
			noteStaticcheck("cannot materialise %s: %v", after, err)
			return nil
		}
		if err := exec.Command("tar", "-xf", archive, "-C", tmp).Run(); err != nil {
			noteStaticcheck("cannot unpack %s: %v", after, err)
			return nil
		}
		os.Remove(archive)
		tree = tmp
	}
	if _, err := os.Stat(filepath.Join(tree, "go.mod")); err != nil {
		fmt.Fprintln(os.Stderr, "skipping staticcheck: no go.mod at the repository root")
		return nil
	}
	args := changedPackages(tree, c)
	if len(args) == 0 {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), staticcheckTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "staticcheck", append([]string{"-f", "json"}, args...)...)
	cmd.Dir = tree
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		noteStaticcheck("a run past %v is not waited for", staticcheckTimeout)
	}
	if err != nil && ctx.Err() == nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			// Exit 1 is staticcheck reporting findings; anything else is a
			// broken run, and its stderr is the only clue.
			noteStaticcheck("%s", tail(stderr.String(), 200))
		}
	}

	// The diff was capped before it was gathered, so a change larger than
	// the cap is judged on the lines that survived, never on ones invented.
	added := addedLines(c.Diff)
	changed := map[string]bool{}
	for _, f := range c.Files {
		changed[f] = true
	}
	var (
		out  []Finding
		seen = map[string]bool{}
	)
	for _, line := range strings.Split(stdout.String(), "\n") {
		if line = strings.TrimSpace(line); line == "" {
			continue
		}
		var p scProblem
		if json.Unmarshal([]byte(line), &p) != nil || !checkCode.MatchString(p.Code) {
			continue
		}
		file := relative(tree, p.Location.File)
		if !changed[file] || !slices.Contains(added[file], p.Location.Line) {
			continue
		}
		key := fmt.Sprintf("%s:%d:%s", file, p.Location.Line, p.Code)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, Finding{
			Job:      "static",
			Rule:     "staticcheck/" + p.Code,
			Severity: staticcheckSeverity(p.Code),
			File:     file,
			Line:     p.Location.Line,
			Message:  p.Message,
		})
	}
	return out
}

// scProblem is one finding in staticcheck's -f json output, one JSON object
// per line. Only the fields the check reads are named.
type scProblem struct {
	Code     string `json:"code"`
	Location struct {
		File string `json:"file"`
		Line int    `json:"line"`
	} `json:"location"`
	Message string `json:"message"`
}

// staticcheckSeverity maps a staticcheck category onto the report's
// severities. SA is a fault the analyser argues for; U is code that serves
// nobody, and S a simplification; ST and QF are style, and anything
// unfamiliar errs toward a note.
func staticcheckSeverity(code string) Severity {
	switch {
	case strings.HasPrefix(code, "SA"):
		return MustFix
	case strings.HasPrefix(code, "S") && !strings.HasPrefix(code, "ST"),
		strings.HasPrefix(code, "U"):
		return Consider
	}
	return Note
}

// changedPackages names the packages of the change's Go files, as patterns
// staticcheck takes. The leading ./ is load-bearing: without it a directory
// reads as a module path and matches nothing.
func changedPackages(tree string, c *Change) []string {
	dirs := map[string]bool{}
	for _, f := range c.Files {
		if !strings.HasSuffix(f, ".go") {
			continue
		}
		dir := filepath.Dir(f)
		if dir == "vendor" || strings.HasPrefix(dir, "vendor/") {
			continue
		}
		// A package the change deleted stands only in the materialised tree
		// where it does; a directory that is nowhere is not a pattern.
		if _, err := os.Stat(filepath.Join(tree, dir)); err != nil {
			continue
		}
		dirs[dir] = true
	}
	var out []string
	for dir := range dirs {
		out = append(out, "./"+dir)
	}
	slices.Sort(out)
	return out
}

// touchesGo is whether the change touches a Go file at all.
func touchesGo(c *Change) bool {
	for _, f := range c.Files {
		if strings.HasSuffix(f, ".go") {
			return true
		}
	}
	return false
}

// noteStaticcheck says why the check said nothing. One line, and only when
// there is a reader who was owed staticcheck's opinion.
func noteStaticcheck(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "skipping staticcheck: "+format+"\n", args...)
}

// tail is the last few bytes of a longer text, for an error message.
func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}
