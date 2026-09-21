package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// OdinFrontend reads Odin through the odin-review-extract sidecar, a small
// program built on Odin's own parser (core:odin). Declaring a review in terms
// of the language's grammar is the point; the sidecar ships in this
// repository and is found on the path.
type OdinFrontend struct{}

func (OdinFrontend) Name() string { return "odin" }

func (OdinFrontend) Covers(path string) bool { return strings.HasSuffix(path, ".odin") }

func (OdinFrontend) Features() Features {
	return FeatSymbols | FeatTests | FeatComments | FeatIndex
}

// odinDecl is one declaration as the sidecar reports it.
type odinDecl struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Line     int    `json:"line"`
	EndLine  int    `json:"end_line"`
	Exported bool   `json:"exported"`
	Test     bool   `json:"test"`
	Text     string `json:"text"`
	Doc      string `json:"doc"`
}

type odinFile struct {
	Name  string     `json:"name"`
	Decls []odinDecl `json:"decls"`
}

type odinOutput struct {
	Files []odinFile `json:"files"`
}

// odinScan materialises the files at the revision into a scratch directory,
// asks the sidecar for their declarations, and maps the answers back to the
// names given. A missing sidecar is the caller's problem: frontends() only
// offers this one when it is on the path.
func odinScan(files []string, root, rev string) ([]odinDecl, map[string][]odinDecl, error) {
	if len(files) == 0 {
		return nil, nil, nil
	}
	dir, err := os.MkdirTemp("", "review-odin")
	if err != nil {
		return nil, nil, err
	}
	defer os.RemoveAll(dir)

	var args []string
	for i, name := range files {
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		scratch := filepath.Join(dir, fmt.Sprintf("%04d%s", i, filepath.Ext(name)))
		if err := os.WriteFile(scratch, source, 0o644); err != nil {
			return nil, nil, err
		}
		args = append(args, scratch)
	}
	cmd := exec.Command("odin-review-extract", args...)
	stdout, err := cmd.Output()
	if err != nil && len(stdout) == 0 {
		return nil, nil, fmt.Errorf("odin-review-extract: %w", err)
	}
	var out odinOutput
	if err := json.Unmarshal(stdout, &out); err != nil {
		return nil, nil, fmt.Errorf("odin-review-extract: %w", err)
	}
	byFile := map[string][]odinDecl{}
	var all []odinDecl
	for _, f := range out.Files {
		base := strings.TrimSuffix(filepath.Base(f.Name), filepath.Ext(f.Name))
		index, err := fmt.Sscanf(base, "%04d", new(int))
		if err != nil || index == 0 {
			continue
		}
		var n int
		if _, err := fmt.Sscanf(base, "%d", &n); err != nil || n >= len(files) {
			continue
		}
		byFile[files[n]] = f.Decls
		all = append(all, f.Decls...)
	}
	return all, byFile, nil
}

// Change appends the declarations, tests and prose the added lines of the
// change's Odin files introduce.
func (g OdinFrontend) Change(root, rev string, c *Change, added map[string][]int) error {
	var covered []string
	for _, name := range c.Files {
		if g.Covers(name) {
			covered = append(covered, name)
		}
	}
	_, byFile, err := odinScan(covered, root, rev)
	if err != nil {
		return err
	}
	for _, name := range covered {
		touched := map[int]bool{}
		for _, line := range added[name] {
			touched[line] = true
		}
		for _, decl := range byFile[name] {
			if !touched[decl.Line] {
				continue
			}
			if decl.Test {
				source, err := at(root, rev, name)
				if err != nil {
					continue
				}
				lines := strings.Split(string(source), "\n")
				end := decl.EndLine
				if end > len(lines) {
					end = len(lines)
				}
				c.Tests = append(c.Tests, Function{
					Name: decl.Name, File: name, Line: decl.Line,
					Body: text(lines, decl.Line, end),
				})
				continue
			}
			c.Symbols = append(c.Symbols, Symbol{
				Name: decl.Name, Kind: decl.Kind, Doc: decl.Doc,
				File: name, Line: decl.Line,
				Exported: decl.Exported, Signature: decl.Text,
			})
		}
		source, err := at(root, rev, name)
		if err != nil {
			continue
		}
		c.Comments = append(c.Comments, commentProse(source, name, added[name])...)
	}
	return nil
}

// Whole reads every declaration in the repository's Odin files, so a new
// name can be checked against the ones it may duplicate.
func (g OdinFrontend) Whole(root, rev string) ([]Declared, error) {
	out, err := git(root, "ls-files", "*.odin")
	if err != nil {
		return nil, err
	}
	var files []string
	for _, name := range strings.Split(strings.TrimSpace(out), "\n") {
		if name != "" && g.Covers(name) {
			files = append(files, name)
		}
	}
	_, byFile, err := odinScan(files, root, rev)
	if err != nil {
		return nil, err
	}
	var index []Declared
	for _, name := range files {
		for _, decl := range byFile[name] {
			if decl.Test {
				continue // Tests are not facts with two owners.
			}
			index = append(index, Declared{Name: decl.Name, Kind: decl.Kind, File: name, Line: decl.Line, Text: decl.Text})
		}
	}
	return index, nil
}
