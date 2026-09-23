package main

import (
	"strings"
	"testing"
)

// added renders a diff adding the lines to one file, in the shape Gather
// produces, so the line-shaped checks can be fed one file at a time.
func added(file string, lines ...string) string {
	var b strings.Builder
	b.WriteString("--- /dev/null\n+++ b/" + file + "\n@@ -0,0 +1," + itoa(len(lines)) + " @@\n")
	for _, l := range lines {
		b.WriteString("+" + l + "\n")
	}
	return b.String()
}

func TestCheckDebugLeftovers(t *testing.T) {
	for _, test := range []struct {
		file, line string
		severity   Severity
		fires      bool
	}{
		{"a.ts", "  debugger;", Consider, true},
		{"a.tsx", "  console.log(x)", Note, true},
		{"a.py", "breakpoint()", Consider, true},
		{"a.rs", "let y = dbg!(x);", Consider, true},
		{"a.go", "spew.Dump(x)", Consider, true},
		{"a.go", `fmt.Println("DEBUG", x)`, Consider, true},
		{"a.go", `fmt.Println("done")`, 0, false},
		{"a.go", "debugger := newDebugger()", 0, false},
		{"a.md", "  debugger;", 0, false},
	} {
		got := checkDebugLeftovers(&Change{Diff: added(test.file, test.line)})
		if (len(got) == 1) != test.fires {
			t.Errorf("%s %q: got %v", test.file, test.line, got)
			continue
		}
		if test.fires && got[0].Severity != test.severity {
			t.Errorf("%s %q: severity %s", test.file, test.line, got[0].Severity)
		}
	}
}

func TestCheckTodos(t *testing.T) {
	c := &Change{Comments: []Located{
		{Text: "TODO handle the empty case", File: "a.go", Line: 1},
		{Text: "TODO(jack) handle the empty case", File: "a.go", Line: 2},
		{Text: "FIXME see #42", File: "a.go", Line: 3},
		{Text: "HACK until PROJ-12 lands", File: "a.go", Line: 4},
		{Text: "the todo list is rendered here", File: "a.go", Line: 5},
	}}
	got := checkTodos(c)
	if len(got) != 1 || got[0].Line != 1 || got[0].Rule != "todo-without-reference" {
		t.Errorf("got %v", got)
	}
}

func TestCheckCommentedCode(t *testing.T) {
	c := &Change{Comments: []Located{
		// One line beyond doubt.
		{Text: "x := parse(input);", File: "a.go", Line: 1},
		// Prose, with a bracket in it.
		{Text: "returns the name (see below)", File: "a.go", Line: 5},
		// Two statement-shaped lines in a row.
		{Text: "if err != nil {", File: "a.go", Line: 10},
		{Text: "return err", File: "a.go", Line: 11},
		{Text: "}", File: "a.go", Line: 12},
		// One statement-shaped line alone is not enough.
		{Text: "for the record:", File: "a.go", Line: 20},
		// A directive is not code.
		{Text: "go:generate stringer -type=Kind", File: "a.go", Line: 30},
	}}
	got := checkCommentedCode(c)
	lines := []int{}
	for _, f := range got {
		lines = append(lines, f.Line)
	}
	if len(got) != 2 || lines[0] != 1 || lines[1] != 10 {
		t.Errorf("got %v", got)
	}
}

func TestCheckSwallowedErrors(t *testing.T) {
	for _, test := range []struct {
		file  string
		lines []string
		fires bool
	}{
		{"a.go", []string{"_ = err"}, true},
		{"a.go", []string{"_, err := f()", "if err != nil {", "\treturn err", "}"}, false},
		{"a.ts", []string{"try { f() } catch (e) {}"}, true},
		{"a.ts", []string{"} catch (e) {", "}"}, true},
		{"a.ts", []string{"} catch (e) {", "  log(e)", "}"}, false},
		{"a.js", []string{"p.catch(() => {})"}, true},
		{"a.py", []string{"except ValueError:", "    pass"}, true},
		{"a.py", []string{"except ValueError: pass"}, true},
		{"a.py", []string{"except ValueError:", "    raise"}, false},
	} {
		got := checkSwallowedErrors(&Change{Diff: added(test.file, test.lines...)})
		if (len(got) == 1) != test.fires {
			t.Errorf("%s %q: got %v", test.file, test.lines, got)
		}
	}
}
