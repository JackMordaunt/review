package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSeverity(t *testing.T) {
	for _, test := range []struct {
		in   string
		want Severity
	}{
		{"must-fix", MustFix},
		{"must fix", MustFix},
		{"MustFix", MustFix},
		{"error", MustFix},
		{" CONSIDER ", Consider},
		{"warning", Consider},
		{"note", Note},
		// A job that invents a word is read as the least serious rather than
		// stopping the run.
		{"catastrophic", Note},
		{"", Note},
	} {
		if got := ParseSeverity(test.in); got != test.want {
			t.Errorf("ParseSeverity(%q) = %v, want %v", test.in, got, test.want)
		}
	}
}

func TestSeverityString(t *testing.T) {
	for severity, want := range map[Severity]string{
		MustFix: "must-fix", Consider: "consider", Note: "note", Severity(9): "unknown",
	} {
		if got := severity.String(); got != want {
			t.Errorf("Severity(%d) = %q, want %q", severity, got, want)
		}
	}
}

func TestSort(t *testing.T) {
	findings := []Finding{
		{Severity: Note, File: "a.go", Line: 1},
		{Severity: MustFix, File: "b.go", Line: 9},
		{Severity: MustFix, File: "b.go", Line: 2},
		{Severity: MustFix, File: "a.go", Line: 50},
		{Severity: Consider, File: "a.go", Line: 1},
	}
	Sort(findings)
	var got []string
	for _, f := range findings {
		got = append(got, f.Severity.String()+" "+f.File+":"+string(rune('0'+f.Line%10)))
	}
	want := []string{"must-fix a.go:0", "must-fix b.go:2", "must-fix b.go:9", "consider a.go:1", "note a.go:1"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestFindingString(t *testing.T) {
	f := Finding{
		Job: "namer", Rule: "noun-for-type", Severity: Consider,
		File: "ico/ico.go", Line: 12, Message: "Stored is an adjective.",
		Fix: "Call it Encoded.",
	}
	got := f.String()
	for _, want := range []string{"consider: ", "ico/ico.go:12: ", "Stored is an adjective.", "→ Call it Encoded.", "[namer/noun-for-type]"} {
		if !strings.Contains(got, want) {
			t.Errorf("%q missing from:\n%s", want, got)
		}
	}
	// A finding about a name rather than a place is located by the name.
	bare := Finding{Job: "namer", Rule: "abbreviation", Symbol: "cfg", Message: "Invented."}
	if !strings.Contains(bare.String(), "cfg: Invented.") {
		t.Errorf("got %q", bare.String())
	}
}

// Suppressed reads the source the finding names, relative to the working
// directory, which is the repository root by the time it is called.
func TestSuppressed(t *testing.T) {
	dir := t.TempDir()
	source := `package x

// nothing here
const a = 1

//review:ignore restates-a-fact the ico package owns the other one
const b = 6

const c = 7

const d = 8

const e = 9
`
	if err := os.WriteFile(filepath.Join(dir, "x.go"), []byte(source), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)

	for _, test := range []struct {
		name    string
		finding Finding
		want    bool
		why     string
	}{{
		name:    "a dismissal just above the line covers it",
		finding: Finding{File: "x.go", Line: 7, Rule: "restates-a-fact"},
		want:    true,
		why:     "the ico package owns the other one",
	}, {
		name:    "a dismissal on the line covers it",
		finding: Finding{File: "x.go", Line: 6, Rule: "restates-a-fact"},
		want:    true,
		why:     "the ico package owns the other one",
	}, {
		name:    "a dismissal does not reach a distant line",
		finding: Finding{File: "x.go", Line: 12, Rule: "restates-a-fact"},
		want:    false,
	}, {
		name:    "a dismissal does not cover another rule",
		finding: Finding{File: "x.go", Line: 7, Rule: "already-named"},
		want:    false,
	}, {
		name:    "a finding with no line is covered anywhere in the file",
		finding: Finding{File: "x.go", Rule: "restates-a-fact"},
		want:    true,
		why:     "the ico package owns the other one",
	}, {
		name:    "a finding with no file is never dismissed",
		finding: Finding{Rule: "restates-a-fact"},
		want:    false,
	}, {
		name:    "a file that is not there dismisses nothing",
		finding: Finding{File: "nowhere.go", Line: 1, Rule: "restates-a-fact"},
		want:    false,
	}} {
		t.Run(test.name, func(t *testing.T) {
			why, ok := Suppressed(test.finding)
			if ok != test.want {
				t.Fatalf("got %v, want %v", ok, test.want)
			}
			if ok && why != test.why {
				t.Errorf("reason: got %q, want %q", why, test.why)
			}
		})
	}
}

func TestSuppressedAll(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "x.go"), []byte("//review:ignore all generated\nconst a = 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	why, ok := Suppressed(Finding{File: "x.go", Line: 2, Rule: "anything-at-all"})
	if !ok || why != "generated" {
		t.Errorf("got (%q, %v), want (generated, true)", why, ok)
	}
}

func TestSuppressedWithoutAReason(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "x.go"), []byte("// review:ignore cannot-fail\nfunc TestX(t *testing.T) {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	why, ok := Suppressed(Finding{File: "x.go", Line: 2, Rule: "cannot-fail"})
	if !ok {
		t.Fatal("a dismissal with a space after the slashes still dismisses")
	}
	if why != "no reason given" {
		t.Errorf("got %q", why)
	}
}

func TestRulesMatch(t *testing.T) {
	for _, test := range []struct {
		dismissed, rule string
		want            bool
	}{
		{"all", "anything", true},
		{"cannot-fail", "cannot-fail", true},
		{"Cannot-Fail", "cannot-fail", true},
		{"cannot-fail", "name-overclaims", false},
	} {
		if got := rulesMatch(test.dismissed, test.rule); got != test.want {
			t.Errorf("rulesMatch(%q, %q) = %v, want %v", test.dismissed, test.rule, got, test.want)
		}
	}
}

func TestAtoi(t *testing.T) {
	for in, want := range map[string]int{"12": 12, " 7 ": 7, "": 0, "x": 0, "-3": -3} {
		if got := atoi(in); got != want {
			t.Errorf("atoi(%q) = %d, want %d", in, got, want)
		}
	}
}

// A finding's id is what a loop uses to answer it and to check it stayed
// answered, so the same finding names itself the same way across runs, and
// a line that moved under it does not change its name.
func TestFindingIDIsStable(t *testing.T) {
	f := Finding{Job: "tests", Rule: "cannot-fail", File: "x_test.go", Line: 4, Symbol: "TestX", Message: "m"}
	identify(&f)
	moved := f
	moved.Line = 9
	identify(&moved)
	if moved.ID != f.ID || f.ID == "" {
		t.Errorf("the id moved with the line: %q then %q", f.ID, moved.ID)
	}
	other := f
	other.Message = "a different finding"
	identify(&other)
	if other.ID == f.ID {
		t.Error("two findings share one id")
	}
}
