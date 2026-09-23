package main

// A test with no assertion in it is the plainest shape of a test that
// cannot fail, and the shape is visible without reading what the test
// means. It is measured here; whether an assertion that is there asserts
// anything is the tests job's.

import (
	"fmt"
	"regexp"
	"strings"
)

// goTestParam reads the name a Go test gives its testing.T, so that a test
// naming it tc or tt is read by the name it uses.
var goTestParam = regexp.MustCompile(`^func \w+\((\w+) \*testing\.T\)`)

// checkTestAssertions reports an added or altered test whose body asserts
// nothing: no failing call, no subtest, no helper handed the test, nothing
// that could make the run report anything but success.
func checkTestAssertions(c *Change) []Finding {
	var out []Finding
	for _, t := range c.Tests {
		if !assertless(t) {
			continue
		}
		out = append(out, Finding{
			Job: "static", Rule: "test-no-assertion", Severity: Consider,
			File: t.File, Line: t.Line, Symbol: t.Name,
			Message: fmt.Sprintf("%s asserts nothing: no call in its body can fail it, so it passes whatever the code does, and can only fail by crashing", t.Name),
			Fix:     "assert the value the test exists to check, or remove the test",
		})
	}
	return out
}

// assertless is whether a test body holds nothing that could fail it, in
// the shapes the tool's languages assert in.
func assertless(t Function) bool {
	body := t.Body
	switch {
	case strings.HasSuffix(t.File, ".go"):
		if strings.HasPrefix(t.Name, "Benchmark") || strings.HasPrefix(t.Name, "Fuzz") || strings.HasPrefix(t.Name, "Example") || t.Name == "TestMain" {
			return false
		}
		param := "t"
		if m := goTestParam.FindStringSubmatch(strings.SplitN(body, "\n", 2)[0]); m != nil {
			param = m[1]
		}
		for _, shape := range []string{".Error", ".Fatal", ".Fail", ".Run(", ".Skip"} {
			if strings.Contains(body, param+shape) {
				return false
			}
		}
		for _, shape := range []string{"panic(", "require.", "assert.", "is."} {
			if strings.Contains(body, shape) {
				return false
			}
		}
		// A test that hands its testing.T to a helper may assert through
		// it, and the helper is not here to read.
		passed := regexp.MustCompile(`[(,]\s*` + regexp.QuoteMeta(param) + `\s*[,)]`)
		return !passed.MatchString(body)
	case grammarOf(t.File) != "":
		for _, shape := range []string{"expect(", "expect.", "assert", "should", "toThrow", "fail(", ".rejects", ".resolves", "throw "} {
			if strings.Contains(body, shape) {
				return false
			}
		}
		return true
	case strings.HasSuffix(t.File, ".odin"):
		for _, shape := range []string{"testing.expect", "testing.fail", "expect(", "expectf(", "expect_value(", "assert(", "panic("} {
			if strings.Contains(body, shape) {
				return false
			}
		}
		return true
	case strings.HasSuffix(t.File, ".py"):
		for _, shape := range []string{"assert ", "assert(", "self.assert", "pytest.raises", "pytest.fail", "raise ", ".assert_"} {
			if strings.Contains(body, shape) {
				return false
			}
		}
		return true
	case strings.HasSuffix(t.File, ".rs"):
		for _, shape := range []string{"assert!", "assert_eq!", "assert_ne!", "panic!", "unwrap()", "expect(", "?;", "should_panic"} {
			if strings.Contains(body, shape) {
				return false
			}
		}
		return true
	}
	return false
}

// tautologies are the assertion shapes that hold whatever the code does: a
// literal true asserted, two literals compared, or an expression compared
// with itself. They are what a test reaches for once a rule says a test
// must assert, and they are visible without reading what the test means.
var tautologies = []*regexp.Regexp{
	// A literal true, or nil where an error is asserted absent.
	regexp.MustCompile(`\b(?:assert|require)\.(?:True|NoError|Nil|Empty)\(\s*\w+\s*,\s*(?:true|nil)\s*\)`),
	regexp.MustCompile(`\bassert\s+(?:True|1|"[^"]+"|'[^']+')\s*(?:,|$)`),
	regexp.MustCompile(`\bassert(?:True|Is)\(\s*True\s*[,)]`),
	regexp.MustCompile(`\bexpect\(\s*true\s*\)\.(?:toBe\(\s*true\s*\)|toBeTruthy\(\))`),
	regexp.MustCompile(`\bassert!\(\s*true\s*\)`),
	regexp.MustCompile(`\b(?:testing\.)?expect\(\s*\w+\s*,\s*true\s*\)`),
	// A literal against a literal.
	regexp.MustCompile(`\bexpect\(\s*(-?\d+|"[^"]*"|'[^']*')\s*\)\.(?:toBe|toEqual|toStrictEqual)\(\s*(-?\d+|"[^"]*"|'[^']*')\s*\)`),
	regexp.MustCompile(`\bassert_eq!\(\s*(-?\d+|"[^"]*")\s*,\s*(-?\d+|"[^"]*")\s*\)`),
	regexp.MustCompile(`\b(?:assert|require)\.Equal\(\s*\w+\s*,\s*(-?\d+|"[^"]*")\s*,\s*(-?\d+|"[^"]*")\s*\)`),
	regexp.MustCompile(`\bassert\s+(-?\d+|"[^"]*"|'[^']*')\s*==\s*(-?\d+|"[^"]*"|'[^']*')`),
}

// selfCompare matches an expression compared with itself, in the shapes the
// languages assert with: x == x, expect(x).toBe(x), assert_eq!(x, x),
// assert.Equal(t, x, x).
var selfCompare = []*regexp.Regexp{
	regexp.MustCompile(`\b([\w.]+(?:\([^()]*\))?)\s*(?:==|!=)\s*([\w.]+(?:\([^()]*\))?)`),
	regexp.MustCompile(`\bexpect\(\s*([^()]+)\s*\)\.(?:toBe|toEqual|toStrictEqual)\(\s*([^()]+)\s*\)`),
	regexp.MustCompile(`\bassert_(?:eq|ne)!\(\s*(.+?)\s*,\s*(.+?)\s*\);?\s*$`),
	regexp.MustCompile(`\b(?:assert|require)\.(?:Equal|NotEqual)\(\s*\w+\s*,\s*(.+?)\s*,\s*(.+?)\s*\)\s*$`),
}

// checkTautologies reports an assertion in an added or altered test that
// holds whatever the code does.
func checkTautologies(c *Change) []Finding {
	var out []Finding
	for _, t := range c.Tests {
		for i, line := range strings.Split(t.Body, "\n") {
			if why := tautological(line); why != "" {
				out = append(out, Finding{
					Job: "static", Rule: "assertion-always-true", Severity: MustFix,
					File: t.File, Line: t.Line + i, Symbol: t.Name,
					Message: fmt.Sprintf("%s asserts %s: %s; the assertion holds whatever the code does, so the test cannot fail on it", t.Name, why, strings.TrimSpace(line)),
					Fix:     "assert the value the code produced against the value it should have",
				})
			}
		}
	}
	return out
}

// tautological says what is tautological about an assertion line, or
// nothing.
func tautological(line string) string {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "#") {
		return ""
	}
	for _, re := range tautologies {
		if re.MatchString(trimmed) {
			return "a constant"
		}
	}
	for _, re := range selfCompare {
		if m := re.FindStringSubmatch(trimmed); m != nil && strings.TrimSpace(m[1]) == strings.TrimSpace(m[2]) {
			return "a value against itself"
		}
	}
	return ""
}
