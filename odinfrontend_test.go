package main

import (
	"os/exec"
	"testing"
)

// The Odin tests need the sidecar; without it the frontend is not offered.
func needSidecar(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("odin-review-extract"); err != nil {
		t.Skip("odin-review-extract is not installed")
	}
}

func odinFixture(t *testing.T) *repo {
	t.Helper()
	r := newRepo(t)
	r.write("src/.keep", "")
	r.commit("odin: begin", "src/.keep")
	return r
}

func TestOdinReadsDeclarations(t *testing.T) {
	needSidecar(t)
	r := odinFixture(t)
	r.write("src/icons.odin", `package icons

// Counts the icons a binary carries.
count_icons :: proc(groups: []Group) -> int { return 0 }

@(test)
test_counts_icons :: proc(t: ^testing.T) {}

Group :: struct {
	id: int,
}

@(private="file")
helper :: proc() {}

MAX_ICONS :: 12
`)
	rev := r.commit("odin: count", "src/icons.odin")

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
		"count_icons": {"func", true},
		"Group":       {"type", true},
		"helper":      {"func", false},
		"MAX_ICONS":   {"value", true},
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
	if s := got["count_icons"]; s.Doc != "Counts the icons a binary carries." {
		t.Errorf("doc %q", s.Doc)
	}
	if len(change.Tests) != 1 || change.Tests[0].Name != "test_counts_icons" {
		t.Fatalf("tests %v", change.Tests)
	}
	if len(change.Tests[0].Body) == 0 {
		t.Error("test body is empty")
	}
}

func TestOdinIndexesTheRepository(t *testing.T) {
	needSidecar(t)
	r := odinFixture(t)
	r.write("src/icons.odin", `package icons

count_icons :: proc(groups: []Group) -> int { return 0 }

@(test)
test_counts_icons :: proc(t: ^testing.T) {}

Group :: struct {
	id: int,
}
`)
	rev := r.commit("odin: index", "src/icons.odin")

	declared, err := OdinFrontend{}.Whole(r.Root, rev)
	if err != nil {
		t.Fatal(err)
	}
	index := map[string]Declared{}
	for _, d := range declared {
		if _, dup := index[d.Name]; dup {
			t.Errorf("%s indexed twice", d.Name)
		}
		index[d.Name] = d
	}
	if d, ok := index["count_icons"]; !ok || d.Kind != "func" || d.Text == "" {
		t.Errorf("count_icons %v", d)
	}
	if d, ok := index["Group"]; !ok || d.Kind != "type" {
		t.Errorf("Group %v", d)
	}
	if _, ok := index["test_counts_icons"]; ok {
		t.Error("test procedure indexed")
	}
}

func TestOdinReadsComments(t *testing.T) {
	needSidecar(t)
	r := odinFixture(t)
	r.write("src/icons.odin", `package icons

count_icons :: proc() {}
`)
	r.commit("odin: empty", "src/icons.odin")
	r.write("src/icons.odin", `package icons

// counts the icons a binary carries
count_icons :: proc() {}
`)
	r.stage("src/icons.odin")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Comments) != 1 || change.Comments[0].Text != "counts the icons a binary carries" {
		t.Fatalf("comments %v", change.Comments)
	}
}
