package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestAddedLines(t *testing.T) {
	for _, test := range []struct {
		name string
		diff string
		want map[string][]int
	}{{
		name: "a new file is added whole",
		diff: `diff --git a/x.go b/x.go
new file mode 100644
--- /dev/null
+++ b/x.go
@@ -0,0 +1,3 @@
+package x
+
+const a = 1
`,
		want: map[string][]int{"x.go": {1, 2, 3}},
	}, {
		name: "context lines advance the count and removals do not",
		diff: `--- a/x.go
+++ b/x.go
@@ -1,4 +1,4 @@
 package x
-const a = 1
+const a = 2
 
 func f() {}
`,
		want: map[string][]int{"x.go": {2}},
	}, {
		name: "a second hunk restarts at its own line",
		diff: `--- a/x.go
+++ b/x.go
@@ -1,2 +1,3 @@
 package x
+const a = 1
 
@@ -20,2 +21,3 @@
 func f() {}
+func g() {}
 
`,
		want: map[string][]int{"x.go": {2, 22}},
	}, {
		name: "each file keeps its own lines",
		diff: `--- a/x.go
+++ b/x.go
@@ -0,0 +1 @@
+package x
--- a/y.go
+++ b/y.go
@@ -0,0 +1 @@
+package y
`,
		want: map[string][]int{"x.go": {1}, "y.go": {1}},
	}, {
		name: "a hunk header without counts still gives the line",
		diff: `--- a/x.go
+++ b/x.go
@@ -7 +7 @@
-const a = 1
+const a = 2
`,
		want: map[string][]int{"x.go": {7}},
	}, {
		name: "a diff touching nothing adds nothing",
		diff: ``,
		want: map[string][]int{},
	}} {
		t.Run(test.name, func(t *testing.T) {
			got := addedLines(test.diff)
			if !reflect.DeepEqual(got, test.want) {
				t.Errorf("got %v, want %v", got, test.want)
			}
		})
	}
}

// The no-newline marker sits between the two sides of a hunk, so counting it
// as a line puts every added line after it one too far down.
func TestAddedLinesIgnoresTheNoNewlineMarker(t *testing.T) {
	diff := `--- a/f.txt
+++ b/f.txt
@@ -1,2 +1,3 @@
 a
-b
\ No newline at end of file
+B
+c
`
	want := map[string][]int{"f.txt": {2, 3}}
	if got := addedLines(diff); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// A deletion writes +++ /dev/null, which must not be read as a line added to
// whichever file came before it.
func TestAddedLinesIgnoresADeletedFile(t *testing.T) {
	diff := `--- a/x.go
+++ b/x.go
@@ -1,1 +1,2 @@
 package x
+const a = 1
diff --git a/y.go b/y.go
deleted file mode 100644
--- a/y.go
+++ /dev/null
@@ -1,2 +0,0 @@
-package y
-const b = 2
`
	want := map[string][]int{"x.go": {2}}
	if got := addedLines(diff); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestTouchedBetween(t *testing.T) {
	lines := []int{4, 9}
	for _, test := range []struct {
		from, to int
		want     bool
	}{
		{1, 3, false},
		{1, 4, true},
		{4, 4, true},
		{5, 8, false},
		{5, 20, true},
		{10, 20, false},
	} {
		if got := touchedBetween(lines, test.from, test.to); got != test.want {
			t.Errorf("touchedBetween(%v, %d, %d) = %v, want %v", lines, test.from, test.to, got, test.want)
		}
	}
	if touchedBetween(nil, 1, 100) {
		t.Error("nothing touched should report false")
	}
}

func TestText(t *testing.T) {
	lines := []string{"one", "two", "three"}
	if got := text(lines, 1, 2); got != "one\ntwo" {
		t.Errorf("got %q", got)
	}
	if got := text(lines, 2, 2); got != "two" {
		t.Errorf("got %q", got)
	}
	// Out of range asks for text that is not there, which is empty rather
	// than a panic.
	if got := text(lines, 0, 2); got != "" {
		t.Errorf("got %q, want empty", got)
	}
	if got := text(lines, 1, 4); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestAtReadsTheRevisionUnderReview(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n\nconst a = 1\n")
	first := r.commit("first", "x.go")
	r.write("x.go", "package x\n\nconst a = 2\n")
	second := r.commit("second", "x.go")
	r.write("x.go", "package x\n\nconst a = 3\n")

	for _, test := range []struct {
		rev  string
		want string
	}{
		{"", "const a = 3"},                     // The working tree.
		{first + ".." + second, "const a = 2"},  // A range is read at its end.
		{first + "..." + second, "const a = 2"}, // So is a symmetric range.
		{first, "const a = 3"},                  // A bare revision diffs to now.
		{second, "const a = 3"},
	} {
		got, err := at(r.Root, test.rev, "x.go")
		if err != nil {
			t.Fatalf("at(%q): %v", test.rev, err)
		}
		if !strings.Contains(string(got), test.want) {
			t.Errorf("at(%q) = %q, want it to contain %q", test.rev, got, test.want)
		}
	}
}

func TestAtReportsAMissingFile(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	first := r.commit("first", "x.go")
	if _, err := at(r.Root, first+".."+first, "nowhere.go"); err == nil {
		t.Error("reading a file that is not in the revision should fail")
	}
}

// Gather with no revision reads the staged change, which is the default the
// command documents and the one a commit hook would use.
func TestGatherStaged(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")

	r.write("x.go", `package x

// Size is how wide a row is.
const Size = 6

// Assemble builds a thing.
func Assemble() {}
`)
	r.write("x_test.go", `package x

import "testing"

func TestAssemble(t *testing.T) {
	Assemble()
}
`)
	r.stage("x.go", "x_test.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Files) != 2 {
		t.Fatalf("files: got %v, want two", change.Files)
	}
	names := map[string]string{}
	for _, s := range change.Symbols {
		names[s.Name] = s.Kind
	}
	if names["Size"] != "value" {
		t.Errorf("Size: got kind %q, want value; symbols were %v", names["Size"], names)
	}
	if names["Assemble"] != "func" {
		t.Errorf("Assemble: got kind %q, want func; symbols were %v", names["Assemble"], names)
	}
	if len(change.Tests) != 1 || change.Tests[0].Name != "TestAssemble" {
		t.Errorf("tests: got %v, want TestAssemble", change.Tests)
	}
	if !strings.Contains(change.Tests[0].Body, "Assemble()") {
		t.Errorf("a test is carried whole, got %q", change.Tests[0].Body)
	}
	var comments []string
	for _, c := range change.Comments {
		comments = append(comments, c.Text)
	}
	if len(comments) != 2 {
		t.Errorf("comments: got %v, want both doc lines", comments)
	}
	if strings.TrimSpace(change.Stat) == "" {
		t.Error("the statistics are empty")
	}
}

// Reviewing a range reads the code that range left behind, not whatever the
// working tree holds now.
func TestGatherRangeIgnoresTheWorkingTree(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	first := r.commit("first", "x.go")
	r.write("x.go", "package x\n\nconst Size = 6\n")
	second := r.commit("second", "x.go")
	// Work that landed after the revision under review.
	r.write("x.go", "package x\n\nconst Size = 6\n\nconst Later = 9\n")
	r.commit("third", "x.go")

	change, err := Gather(first+".."+second, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range change.Symbols {
		if s.Name == "Later" {
			t.Fatalf("read a symbol added after the revision under review: %v", change.Symbols)
		}
	}
	if len(change.Symbols) != 1 || change.Symbols[0].Name != "Size" {
		t.Fatalf("symbols: got %v, want only Size", change.Symbols)
	}
}

// The shortlist is what makes the duplication job cheap, so a constant
// holding the same literal as an existing one has to reach it.
func TestGatherFindsTheTwinConstant(t *testing.T) {
	r := newRepo(t)
	r.write("ico/writer.go", "package ico\n\nconst (\n\tdirectorySize = 6\n)\n")
	first := r.commit("first", "ico/writer.go")
	r.write("exe/exe.go", "package exe\n\nconst (\n\tgroupHeaderSize = 6\n)\n")
	second := r.commit("second", "exe/exe.go")

	change, err := Gather(first+".."+second, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	candidates := strings.Join(change.Candidates["groupHeaderSize"], "\n")
	if !strings.Contains(candidates, "directorySize = 6") {
		t.Errorf("the twin constant is missing from the shortlist:\n%s", candidates)
	}
	if !strings.Contains(candidates, "same value") {
		t.Errorf("the twin is not marked as holding the same value:\n%s", candidates)
	}
}

func TestGatherEmptyChange(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(change.Diff) != "" {
		t.Errorf("nothing is staged, so the diff should be empty, got %q", change.Diff)
	}
}

// A loop rewritten inside a function body is work on what the function does.
// Reading it as a new name is what made a purely mechanical commit report a
// dozen names it never introduced.
func TestGatherIgnoresABodyChange(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", `package x

func existing() int {
	total := 0
	for i := 0; i < 3; i++ {
		total += i
	}
	return total
}
`)
	first := r.commit("first", "x.go")
	r.write("x.go", `package x

func existing() int {
	total := 0
	for i := range 3 {
		total += i
	}
	return total
}

func added() int { return 1 }
`)
	second := r.commit("second", "x.go")

	change, err := Gather(first+".."+second, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, s := range change.Symbols {
		names = append(names, s.Name)
	}
	if len(names) != 1 || names[0] != "added" {
		t.Errorf("got %v, want only the declaration the change adds", names)
	}
}

// A test is judged by what it asserts, so a change anywhere inside one is a
// change to the test.
func TestGatherReadsATestWhoseBodyChanged(t *testing.T) {
	r := newRepo(t)
	r.write("x_test.go", "package x\n\nimport \"testing\"\n\nfunc TestX(t *testing.T) {\n\tt.Log(\"one\")\n}\n")
	first := r.commit("first", "x_test.go")
	r.write("x_test.go", "package x\n\nimport \"testing\"\n\nfunc TestX(t *testing.T) {\n\tt.Skip(\"two\")\n}\n")
	second := r.commit("second", "x_test.go")

	change, err := Gather(first+".."+second, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Tests) != 1 || change.Tests[0].Name != "TestX" {
		t.Fatalf("got %v, want TestX", change.Tests)
	}
	if !strings.Contains(change.Tests[0].Body, "t.Skip") {
		t.Errorf("the test is carried whole, got %q", change.Tests[0].Body)
	}
}

func TestIsTest(t *testing.T) {
	for name, want := range map[string]bool{
		"TestX": true, "FuzzX": true, "BenchmarkX": true,
		"Assemble": false, "testHelper": false, "Tested": true,
	} {
		if got := isTest(name); got != want {
			t.Errorf("isTest(%q) = %v, want %v", name, got, want)
		}
	}
}
