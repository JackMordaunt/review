package main

import (
	"strings"
	"testing"
)

func TestPythonReadsDeclarations(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/.keep", "")
	r.commit("py: begin", "src/.keep")
	r.write("src/icons.py", `"""Icons."""
MAX_ICONS = 12
_hidden: int = 4

# Reads the icons a file holds.
def read_icons(src):
    inner = 1
    def nested():
        return inner
    return []

class Reader:
    size = 0
    def method(self):
        return 1
`)
	r.write("tests/test_icons.py", `from src.icons import read_icons

def test_reads_icons():
    assert read_icons("x") == []

def test_smoke():
    read_icons("y")
`)
	rev := r.commit("py: first", "src/icons.py", "tests/test_icons.py")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Symbol{}
	for _, s := range change.Symbols {
		got[s.Name] = s
	}
	for name, want := range map[string]struct {
		kind     string
		exported bool
	}{
		"MAX_ICONS":  {"value", true},
		"_hidden":    {"value", false},
		"read_icons": {"func", true},
		"Reader":     {"type", true},
	} {
		s, ok := got[name]
		if !ok {
			t.Errorf("%s not read", name)
			continue
		}
		if s.Kind != want.kind || s.Exported != want.exported {
			t.Errorf("%s: got %s exported=%v, want %s exported=%v", name, s.Kind, s.Exported, want.kind, want.exported)
		}
	}
	for _, inner := range []string{"inner", "nested", "size", "method", "test_reads_icons"} {
		if _, ok := got[inner]; ok {
			t.Errorf("%s is not a module-level declaration", inner)
		}
	}
	if got["read_icons"].Doc != "Reads the icons a file holds." || !strings.Contains(got["read_icons"].Body, "return []") {
		t.Errorf("got %+v", got["read_icons"])
	}
	names := map[string]bool{}
	for _, test := range change.Tests {
		names[test.Name] = true
	}
	if len(change.Tests) != 2 || !names["test_reads_icons"] || !names["test_smoke"] {
		t.Errorf("tests: %v", change.Tests)
	}
	if len(change.Uncovered) != 0 {
		t.Errorf("uncovered: %v", change.Uncovered)
	}
	// The assertion check reads Python's shapes.
	got2 := checkTestAssertions(change)
	if len(got2) != 1 || got2[0].Symbol != "test_smoke" {
		t.Errorf("assertions: %v", got2)
	}
}

func TestRustReadsDeclarations(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/.keep", "")
	r.commit("rs: begin", "src/.keep")
	r.write("src/icons.rs", `pub const MAX_ICONS: usize = 12;
static HIDDEN: i32 = 4;
/// A reader of icons.
pub struct Reader { size: usize }
enum Kind { Small, Large }
pub type Group = Vec<u8>;
pub fn read_icons(src: &str) -> Vec<u8> { Vec::new() }
fn helper() -> i32 { 3 }
impl Reader {
    pub fn new() -> Self { Reader { size: 0 } }
}
#[cfg(test)]
mod tests {
    #[test]
    fn reads_icons() { assert_eq!(super::read_icons("x").len(), 0); }
    #[tokio::test]
    async fn smoke() { super::read_icons("y"); }
}
`)
	rev := r.commit("rs: first", "src/icons.rs")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Symbol{}
	for _, s := range change.Symbols {
		got[s.Name] = s
	}
	for name, want := range map[string]struct {
		kind     string
		exported bool
	}{
		"MAX_ICONS":  {"value", true},
		"HIDDEN":     {"value", false},
		"Reader":     {"type", true},
		"Kind":       {"type", false},
		"Group":      {"type", true},
		"read_icons": {"func", true},
		"helper":     {"func", false},
		"new":        {"func", true},
	} {
		s, ok := got[name]
		if !ok {
			t.Errorf("%s not read", name)
			continue
		}
		if s.Kind != want.kind || s.Exported != want.exported {
			t.Errorf("%s: got %s exported=%v, want %s exported=%v", name, s.Kind, s.Exported, want.kind, want.exported)
		}
	}
	if got["Reader"].Doc != "A reader of icons." {
		t.Errorf("doc: %q", got["Reader"].Doc)
	}
	names := map[string]bool{}
	for _, test := range change.Tests {
		names[test.Name] = true
	}
	if len(change.Tests) != 2 || !names["reads_icons"] || !names["smoke"] {
		t.Errorf("tests: %v", change.Tests)
	}
	if _, ok := got["reads_icons"]; ok {
		t.Error("a test was read as a declaration")
	}
	got2 := checkTestAssertions(change)
	if len(got2) != 1 || got2[0].Symbol != "smoke" {
		t.Errorf("assertions: %v", got2)
	}
}

// A deleted Python or Rust test is read by its own shape.
func TestDeletedTestsInPythonAndRust(t *testing.T) {
	diff := "--- a/tests/test_icons.py\n+++ b/tests/test_icons.py\n@@ -1,3 +1,1 @@\n-def test_reads_icons():\n-    assert True\n-\n" +
		"--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1,4 +1,2 @@\n-#[test]\n-fn reads_icons() {}\n-fn helper() {}\n-\n"
	got := checkDeletedTests(&Change{Diff: diff})
	if len(got) != 2 {
		t.Fatalf("got %v", got)
	}
	if got[0].File != "src/lib.rs" || !strings.Contains(got[0].Message, `"reads_icons"`) || strings.Contains(got[0].Message, "helper") {
		t.Errorf("rust: %v", got[0])
	}
	if got[1].File != "tests/test_icons.py" || !strings.Contains(got[1].Message, `"test_reads_icons"`) {
		t.Errorf("python: %v", got[1])
	}
}
