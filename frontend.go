package main

import (
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// Features names what a frontend can read out of a language, so a job can be
// skipped with a reason where the reading is not possible rather than faked.
type Features uint8

const (
	// FeatSymbols covers the declarations a change adds, which the
	// duplication and namer jobs read.
	FeatSymbols Features = 1 << iota
	// FeatTests covers whole test functions, which the tests job reads.
	FeatTests
	// FeatComments covers the prose a change adds, which the claims job
	// reads.
	FeatComments
	// FeatIndex covers the declarations already in the repository, which the
	// duplication shortlist is built from.
	FeatIndex
)

// String renders the mask as the feature names, comma separated.
func (f Features) String() string {
	names := []struct {
		bit  Features
		name string
	}{
		{FeatSymbols, "symbols"},
		{FeatTests, "tests"},
		{FeatComments, "comments"},
		{FeatIndex, "index"},
	}
	var out []string
	for _, n := range names {
		if f&n.bit != 0 {
			out = append(out, n.name)
		}
	}
	if len(out) == 0 {
		return "nothing"
	}
	s := out[0]
	for _, rest := range out[1:] {
		s += ", " + rest
	}
	return s
}

// Frontend reads one language. Its Change method appends what the change
// adds; its Whole method reads the declarations already in the repository,
// which is what a new name is judged against. Language judgment — what
// counts as exported, which functions are tests, where a doc comment sits —
// is the frontend's, so the jobs never carry it.
type Frontend interface {
	Name() string
	// Covers reports whether the path is this frontend's language.
	Covers(path string) bool
	Features() Features
	// Change appends the declarations, tests and prose the added lines of
	// this frontend's files introduce.
	Change(root, rev string, c *Change, added map[string][]int) error
	// Whole reads the declarations in the repository at the revision.
	Whole(root, rev string) ([]Declared, error)
}

// frontends returns the readers, in coverage order. A frontend whose
// dependencies are not installed is left out rather than asked for and
// failed, so its files fall to the heuristic reader and say why.
func frontends() []Frontend {
	readers := []Frontend{GoFrontend{}}
	// The TypeScript frontend is only offered when ast-grep is installed; its
	// files fall to the heuristic reader otherwise, which says why.
	if _, err := exec.LookPath("ast-grep"); err == nil {
		readers = append(readers, TSFrontend{})
	}
	// Same for the Odin sidecar, which is built from sidecar/odin in this
	// repository.
	if _, err := exec.LookPath("odin-review-extract"); err == nil {
		readers = append(readers, OdinFrontend{})
	}
	return append(readers, Heuristic{})
}

// reader picks the first frontend that covers the path.
func reader(path string, frontends []Frontend) Frontend {
	for _, f := range frontends {
		if f.Covers(path) {
			return f
		}
	}
	return nil
}

// read parses the change's files through the frontend that covers each. What
// a language cannot provide is skipped with a line on stderr, so a job's
// "nothing to read" is explained rather than mysterious. Every file that
// went without its part is named in the change's uncovered list, because a
// job that read nothing reports nothing, and the program reading the report
// has to know which silence is real.
func (c *Change) read(root, rev string, frontends []Frontend) {
	added := addedLines(c.Diff)

	// owned records, per frontend, the paths it covers in this change, so a
	// missing feature is reported once per language rather than per file.
	owned := map[Frontend]map[string]bool{}
	exts := map[Frontend]map[string]bool{}
	for _, name := range c.Files {
		f := reader(name, frontends)
		if f == nil {
			// A file no reader could plausibly exist for — prose, data,
			// configuration — is not a promise the review broke; a code
			// file with no reader is, because a job that would have read
			// it read nothing.
			if isCodeFile(name) {
				c.Uncovered = append(c.Uncovered, Gap{File: name, Reason: "no reader"})
			}
			continue
		}
		if owned[f] == nil {
			owned[f] = map[string]bool{}
			exts[f] = map[string]bool{}
		}
		owned[f][name] = true
		exts[f][filepath.Ext(name)] = true
	}
	if len(owned) == 0 {
		return
	}

	missing := func(covers map[string]bool, f Frontend, want Features, jobs string) {
		if f.Features()&want != 0 {
			return
		}
		extensions := make([]string, 0, len(exts[f]))
		for ext := range exts[f] {
			extensions = append(extensions, ext)
		}
		slices.Sort(extensions)
		fmt.Fprintf(os.Stderr, "  skipping %s for %s (%d file(s), %s): no parser\n", jobs, strings.Join(extensions, ", "), len(covers), f.Name())
		for _, name := range slices.Sorted(maps.Keys(covers)) {
			c.Uncovered = append(c.Uncovered, Gap{File: name, Reason: "no " + jobs + " parser"})
		}
	}

	for f, covers := range owned {
		if err := f.Change(root, rev, c, added); err != nil {
			fmt.Fprintf(os.Stderr, "  %s: %v\n", f.Name(), err)
			for _, name := range slices.Sorted(maps.Keys(covers)) {
				c.Uncovered = append(c.Uncovered, Gap{File: name, Reason: "reader failed"})
			}
			continue
		}
		missing(covers, f, FeatSymbols, "duplication, namer")
		missing(covers, f, FeatTests, "tests")
		missing(covers, f, FeatComments, "claims")
	}
}
