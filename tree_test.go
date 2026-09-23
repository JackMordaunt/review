package main

import (
	"os"
	"slices"
	"strings"
	"testing"
)

// A range's end is a tree git holds and the filesystem does not; it is
// materialised once, in Go, and every reader reads files from it.
func TestTreeMaterialisesARange(t *testing.T) {
	r := newRepo(t)
	r.write("a.go", "package x\n\nvar a = 1\n")
	r.write("bin/blob", "\x00\x01\x02")
	first := r.commit("first", "a.go", "bin/blob")
	r.write("a.go", "package x\n\nvar a = 2\n")
	r.write("b.go", "package x\n")
	second := r.commit("second", "a.go", "b.go")
	r.write("a.go", "package x\n\nvar a = 3 // working tree\n")

	tree, err := treeAt(r.Root, first+".."+second)
	if err != nil {
		t.Fatal(err)
	}
	if tree.Dir() == r.Root {
		t.Fatal("a range was read from the working tree")
	}
	data, err := tree.Read("a.go")
	if err != nil || !strings.Contains(string(data), "a = 2") {
		t.Errorf("read %q, %v; want the range's end", data, err)
	}
	files, err := tree.Files()
	if err != nil || !slices.Equal(files, []string{"a.go", "b.go", "bin/blob"}) {
		t.Errorf("files %v, %v", files, err)
	}
	sources, err := tree.Sources()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := sources["bin/blob"]; ok {
		t.Error("a binary file was read as a source")
	}
	if !tree.Exists("b.go") || tree.Exists("nowhere.go") || tree.Exists("bin") {
		t.Error("exists is wrong about a file, a missing file, or a directory")
	}
	// The same range is the same tree.
	again, err := treeAt(r.Root, first+".."+second)
	if err != nil || again != tree {
		t.Error("the tree was materialised twice")
	}
	dir := tree.Dir()
	closeTrees()
	if _, err := os.Stat(dir); err == nil {
		t.Error("the scratch tree survived closing")
	}
}

// The working tree is read in place, staged files included.
func TestTreeReadsTheWorkingTreeInPlace(t *testing.T) {
	r := newRepo(t)
	r.write("a.go", "package x\n")
	r.commit("first", "a.go")
	r.write("b.go", "package x\n")
	r.stage("b.go")
	tree, err := treeAt(r.Root, "")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Dir() != r.Root {
		t.Errorf("read from %s, want the repository", tree.Dir())
	}
	files, _ := tree.Files()
	if !slices.Contains(files, "b.go") {
		t.Errorf("the staged file is not listed: %v", files)
	}
}

func TestTreeRefusesAnUnknownRevision(t *testing.T) {
	r := newRepo(t)
	r.write("a.go", "package x\n")
	r.commit("first", "a.go")
	if _, err := treeAt(r.Root, "nowhere..nothing"); err == nil {
		t.Error("an unknown revision was materialised")
	}
}
