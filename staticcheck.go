package main

// staticcheck is the Go analyser beyond vet, and review has nothing to teach
// it about Go. It runs as one of the analysers, over the packages the
// change touches, and its findings are kept to the change's added lines
// like every other analyser's opinions.

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
)

// checkCode matches a staticcheck finding code, such as SA4006 or S1002.
// Anything else staticcheck emits — compile errors, for instance — is not a
// finding about the code, and the build has already reported it.
var checkCode = regexp.MustCompile(`^[A-Z]+[0-9]+$`)

// staticcheckAnalyser runs staticcheck with JSON output over the packages
// the change touched.
var staticcheckAnalyser = Analyser{
	Name:   "staticcheck",
	Covers: isGo,
	Ready:  goReady("staticcheck"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		pkgs := goPackages(tree, files)
		if len(pkgs) == 0 {
			return nil, nil
		}
		out, err := execute(ctx, tree, nil, "staticcheck", append([]string{"-f", "json"}, pkgs...)...)
		if err != nil {
			return nil, err
		}
		var diagnostics []Diagnostic
		for _, line := range strings.Split(string(out), "\n") {
			var p scProblem
			if json.Unmarshal([]byte(line), &p) != nil || !checkCode.MatchString(p.Code) {
				continue
			}
			diagnostics = append(diagnostics, Diagnostic{
				File: relative(tree, p.Location.File), Line: p.Location.Line,
				Code: p.Code, Message: p.Message, Severity: staticcheckSeverity(p.Code),
			})
		}
		return diagnostics, nil
	},
}

// checkStaticcheck is staticcheck alone, for the readers that want only it.
func checkStaticcheck(root, rev string, c *Change) []Finding {
	return checkAnalysers(root, rev, c, staticcheckAnalyser)
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

// tail is the last few bytes of a longer text, for an error message.
func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}
