package main

// A review reads the repository as it stands at the end of the change. For
// the staged change and a bare revision that is the working tree; for a
// range it is a tree the working directory may have left behind, which git
// holds and the filesystem does not. The tree here makes both readable the
// same way, and materialises a range's end once, in Go, so that every
// reader after the first reads files rather than asking git for each.

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// Tree is the repository's files at the end of the change.
type Tree struct {
	// dir is where the files are read from: the repository root, or a
	// scratch copy of the revision.
	dir string
	// root is the repository, which is what git is asked about.
	root string
	// rev is the revision materialised, or empty for the working tree.
	rev string

	once  sync.Once
	files []string
	err   error

	sourcesOnce sync.Once
	sources     map[string][]byte
	sourcesErr  error
}

var (
	treesMu sync.Mutex
	trees   = map[string]*Tree{}
	scratch []string
)

// treeAt is the tree the change arrives at. A range's end is materialised on
// the first ask and shared by every reader after it; the working tree is
// read in place.
func treeAt(root, rev string) (*Tree, error) {
	after, ranged := ends(rev)
	if !ranged {
		return &Tree{dir: root, root: root}, nil
	}
	treesMu.Lock()
	defer treesMu.Unlock()
	key := root + "\x00" + after
	if t, ok := trees[key]; ok {
		return t, nil
	}
	dir, err := materialise(root, after)
	if err != nil {
		return nil, err
	}
	t := &Tree{dir: dir, root: root, rev: after}
	trees[key] = t
	scratch = append(scratch, dir)
	return t, nil
}

// materialise writes the revision's files to a scratch directory, read out
// of git's own archive of it: one ask, however many files, and no tar
// program to find.
func materialise(root, rev string) (string, error) {
	cmd := exec.Command("git", "archive", "--format=tar", rev)
	cmd.Dir = root
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	archive, err := cmd.Output()
	if err != nil {
		return "", errors.New("git archive " + rev + ": " + strings.TrimSpace(stderr.String()))
	}
	dir, err := os.MkdirTemp("", "review-tree-")
	if err != nil {
		return "", err
	}
	reader := tar.NewReader(bytes.NewReader(archive))
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			os.RemoveAll(dir)
			return "", err
		}
		// Only regular files are read; a link is not a source file, and a
		// path that climbs out of the directory is not written anywhere.
		name := filepath.Clean(header.Name)
		if header.Typeflag != tar.TypeReg || strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
			continue
		}
		full := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			os.RemoveAll(dir)
			return "", err
		}
		data, err := io.ReadAll(reader)
		if err != nil {
			os.RemoveAll(dir)
			return "", err
		}
		if err := os.WriteFile(full, data, 0o644); err != nil {
			os.RemoveAll(dir)
			return "", err
		}
	}
	return dir, nil
}

// closeTrees removes what materialising left behind. It is deferred by the
// command, so a run that fails still cleans up.
func closeTrees() {
	treesMu.Lock()
	defer treesMu.Unlock()
	for _, dir := range scratch {
		os.RemoveAll(dir)
	}
	scratch = nil
	trees = map[string]*Tree{}
}

// Read is one file's content as it stands at the end of the change.
func (t *Tree) Read(path string) ([]byte, error) {
	return os.ReadFile(filepath.Join(t.dir, path))
}

// Dir is where the tree's files can be read by a program that reads trees
// rather than files, such as an analyser.
func (t *Tree) Dir() string { return t.dir }

// Exists reports whether the tree holds the path as a file.
func (t *Tree) Exists(path string) bool {
	info, err := os.Stat(filepath.Join(t.dir, path))
	return err == nil && !info.IsDir()
}

// Files lists the tracked paths at the end of the change, asked of git once
// and kept. The staged change is tracked by the index, which is what
// ls-files reads.
func (t *Tree) Files() ([]string, error) {
	t.once.Do(func() {
		var out string
		if t.rev == "" {
			out, t.err = git(t.root, "ls-files")
		} else {
			out, t.err = git(t.root, "ls-tree", "-r", "--name-only", t.rev)
		}
		if t.err != nil {
			return
		}
		for _, line := range strings.Split(out, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				t.files = append(t.files, line)
			}
		}
	})
	return t.files, t.err
}

// Sources reads every tracked file that is text, so that a search over the
// repository is a loop over memory rather than a program run. Binary files
// are left out by the cheapest test there is: a NUL byte in the first
// kilobyte.
func (t *Tree) Sources() (map[string][]byte, error) {
	t.sourcesOnce.Do(func() {
		files, err := t.Files()
		if err != nil {
			t.sourcesErr = err
			return
		}
		out := make(map[string][]byte, len(files))
		for _, name := range files {
			data, err := t.Read(name)
			if err != nil {
				continue // A tracked path the tree cannot read is a link or gone.
			}
			head := data
			if len(head) > 1024 {
				head = head[:1024]
			}
			if bytes.IndexByte(head, 0) >= 0 {
				continue
			}
			out[name] = data
		}
		t.sources = out
	})
	return t.sources, t.sourcesErr
}

// Line is one line of a file at the end of the change, trimmed, or empty
// where the file or the line is not there.
func (t *Tree) Line(path string, line int) string {
	if line < 1 {
		return ""
	}
	data, err := t.Read(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	if line > len(lines) {
		return ""
	}
	return strings.TrimSpace(lines[line-1])
}

// at reads a file as it stands at the end of the change under review, so that
// reviewing an old commit reads the code that commit left behind rather than
// whatever the working tree holds now.
func at(root, rev, path string) ([]byte, error) {
	t, err := treeAt(root, rev)
	if err != nil {
		return nil, err
	}
	return t.Read(path)
}

// ends reports the revision a range arrives at, and whether it is a range at
// all. Both A..B and A...B are reviewed as B.
func ends(rev string) (string, bool) {
	_, after, found := strings.Cut(rev, "..")
	if !found {
		return rev, false
	}
	return strings.TrimPrefix(after, "."), true
}
