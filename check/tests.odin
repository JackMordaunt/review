package check

// A test with no assertion in it is the plainest shape of a test that
// cannot fail, and the shape is visible without reading what the test
// means. Whether an assertion that is there asserts anything is the tests
// job's, except for the tautologies a pattern can see.

import "core:fmt"
import "core:strings"

import "../change"
import "../finding"

// go_test_param reads the name a Go test gives its testing.T, so that a
// test naming it tc or tt is read by the name it uses.
go_test_param :: `^func \w+\((\w+) \*testing\.T\)`

// check_test_assertions reports an added or altered test whose body
// asserts nothing: no failing call, no subtest, no helper handed the test.
check_test_assertions :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for t in s.c.tests {
		if !assertless(t) {
			continue
		}
		append(
			out,
			static(
				"test-no-assertion",
				.Consider,
				fmt.aprintf(
					"%s asserts nothing: no call in its body can fail it, so it passes whatever the code does, and can only fail by crashing",
					t.name,
				),
				"assert the value the test exists to check, or remove the test",
				file = t.file,
				line = t.line,
				symbol = t.name,
			),
		)
	}
}

// assertless is whether a test body holds nothing that could fail it, in
// the shapes the tool's languages assert in.
assertless :: proc(t: change.Function) -> bool {
	body := t.body
	switch {
	case strings.has_suffix(t.file, ".go"):
		if strings.has_prefix(t.name, "Benchmark") ||
		   strings.has_prefix(t.name, "Fuzz") ||
		   strings.has_prefix(t.name, "Example") ||
		   t.name == "TestMain" {
			return false
		}
		param := "t"
		if m, ok := capture(go_test_param, subject_of(body)); ok {
			param = m[1]
		}
		for shape in ([]string{".Error", ".Fatal", ".Fail", ".Run(", ".Skip"}) {
			if strings.contains(
				body,
				strings.concatenate({param, shape}, context.temp_allocator),
			) {
				return false
			}
		}
		for shape in ([]string{"panic(", "require.", "assert.", "is."}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		// A test that hands its testing.T to a helper may assert through
		// it, and the helper is not here to read.
		return !matches(fmt.tprintf(`[(,]\s*%s\s*[,)]`, param), body)
	case grammar_of(t.file) != "":
		for shape in ([]string{"expect(", "expect.", "assert", "should", "toThrow", "fail(", ".rejects", ".resolves", "throw "}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		return true
	case strings.has_suffix(t.file, ".odin"):
		for shape in ([]string{"testing.expect", "testing.fail", "expect(", "expectf(", "expect_value(", "assert(", "panic("}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		return true
	case strings.has_suffix(t.file, ".py"):
		for shape in ([]string{"assert ", "assert(", "self.assert", "pytest.raises", "pytest.fail", "raise ", ".assert_"}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		return true
	case strings.has_suffix(t.file, ".rs"):
		for shape in ([]string{"assert!", "assert_eq!", "assert_ne!", "panic!", "unwrap()", "expect(", "?;", "should_panic"}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		return true
	case strings.has_suffix(t.file, ".java"):
		// The shapes read are assert in any spelling — the keyword,
		// assertEquals, assertThat — a mock verified, a throw, and fail.
		for shape in ([]string{"assert", "fail(", "verify(", "throw ", "expectThrows("}) {
			if strings.contains(body, shape) {
				return false
			}
		}
		return true
	}
	return false
}

// tautologies are the assertion shapes that hold whatever the code does:
// a literal true asserted, two literals compared. They are what a test
// reaches for once a rule says a test must assert.
@(private = "file")
tautologies := []string {
	`\b(?:assert|require)\.(?:True|NoError|Nil|Empty)\(\s*\w+\s*,\s*(?:true|nil)\s*\)`,
	`\bassert\s+(?:True|1|"[^"]+"|'[^']+')\s*(?:,|$)`,
	`\bassert(?:True|Is)\(\s*True\s*[,)]`,
	`\bexpect\(\s*true\s*\)\.(?:toBe\(\s*true\s*\)|toBeTruthy\(\))`,
	`\bassert!\(\s*true\s*\)`,
	`\b(?:testing\.)?expect\(\s*\w+\s*,\s*true\s*\)`,
	`\bexpect\(\s*(-?\d+|"[^"]*"|'[^']*')\s*\)\.(?:toBe|toEqual|toStrictEqual)\(\s*(-?\d+|"[^"]*"|'[^']*')\s*\)`,
	`\bassert_eq!\(\s*(-?\d+|"[^"]*")\s*,\s*(-?\d+|"[^"]*")\s*\)`,
	`\b(?:assert|require)\.Equal\(\s*\w+\s*,\s*(-?\d+|"[^"]*")\s*,\s*(-?\d+|"[^"]*")\s*\)`,
	`\bassert\s+(-?\d+|"[^"]*"|'[^']*')\s*==\s*(-?\d+|"[^"]*"|'[^']*')`,
}

// self_compare matches an expression compared with itself, in the shapes
// the languages assert with: x == x, expect(x).toBe(x), assert_eq!(x, x),
// assert.Equal(t, x, x).
@(private = "file")
self_compare := []string {
	`\b([\w.]+(?:\([^()]*\))?)\s*(?:==|!=)\s*([\w.]+(?:\([^()]*\))?)`,
	`\bexpect\(\s*([^()]+)\s*\)\.(?:toBe|toEqual|toStrictEqual)\(\s*([^()]+)\s*\)`,
	`\bassert_(?:eq|ne)!\(\s*(.+?)\s*,\s*(.+?)\s*\);?\s*$`,
	`\b(?:assert|require)\.(?:Equal|NotEqual)\(\s*\w+\s*,\s*(.+?)\s*,\s*(.+?)\s*\)\s*$`,
}

// check_tautologies reports an assertion in an added or altered test that
// holds whatever the code does.
check_tautologies :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for t in s.c.tests {
		rest := t.body
		i := 0
		for line in strings.split_lines_iterator(&rest) {
			if why := tautological(line); why != "" {
				append(
					out,
					static(
						"assertion-always-true",
						.Must_Fix,
						fmt.aprintf(
							"%s asserts %s: %s; the assertion holds whatever the code does, so the test cannot fail on it",
							t.name,
							why,
							strings.trim_space(line),
						),
						"assert the value the code produced against the value it should have",
						file = t.file,
						line = t.line + i,
						symbol = t.name,
					),
				)
			}
			i += 1
		}
	}
}

// tautological says what is tautological about an assertion line, or
// nothing.
tautological :: proc(line: string) -> string {
	trimmed := strings.trim_space(line)
	if trimmed == "" || strings.has_prefix(trimmed, "//") || strings.has_prefix(trimmed, "#") {
		return ""
	}
	for pattern in tautologies {
		if matches(pattern, trimmed) {
			return "a constant"
		}
	}
	for pattern in self_compare {
		if m, ok := capture(pattern, trimmed);
		   ok && len(m) > 2 && strings.trim_space(m[1]) == strings.trim_space(m[2]) {
			return "a value against itself"
		}
	}
	return ""
}
