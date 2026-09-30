/*
Package tree reads the repository as it stands at the end of a change. For
the staged change and a bare revision that is the working tree, read in
place; for a range it is a tree git holds and the filesystem does not, so
the range's end is written once to a scratch directory and read from there.
Every reader after that reads files, which is what a sidecar can be handed.
*/
package tree

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "jm:sh"
import "jm:tar"

import "../git"

// Tree is the repository's files at the end of the change.
Tree :: struct {
	// dir is where the files are read from: the repository root, or a
	// scratch copy of the revision.
	dir:  string,
	// root is the repository, which is what git is asked about.
	root: string,
	// rev is the revision materialised, or empty for the working tree.
	rev:  string,
}

// at is the tree the change arrives at. A range's end is materialised;
// the working tree is read in place.
at :: proc(root, rev: string, allocator := context.allocator) -> (t: Tree, ok: bool) {
	after, ranged := ends(rev)
	if !ranged {
		return Tree{dir = root, root = root}, true
	}
	dir := materialise(root, after, allocator) or_return
	return Tree{dir = dir, root = root, rev = after}, true
}

// close removes what materialising left behind.
close :: proc(t: Tree) {
	if t.rev != "" && t.dir != t.root {
		os.remove_all(t.dir)
	}
}

// materialise writes the revision's files to a scratch directory, out of
// git's own archive of it: one ask, however many files, unpacked here
// rather than by a tar program the platform may not have.
materialise :: proc(root, rev: string, allocator := context.allocator) -> (dir: string, ok: bool) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	scratch, err := os.make_directory_temp(temp, "review-tree-*", allocator)
	if err != nil {
		return "", false
	}
	r := sh.exec({"git", "archive", "--format=tar", rev}, {dir = root}, context.temp_allocator)
	if !r.ok {
		os.remove_all(scratch)
		return "", false
	}
	if _, unpacked := tar.extract(transmute([]byte)r.stdout, scratch); unpacked != .None {
		os.remove_all(scratch)
		return "", false
	}
	// The analysers report real paths, and macOS's temp directory is under
	// /var, a link to /private/var: the tree is named as they will name it,
	// or no finding would land inside it.
	return os.get_absolute_path(scratch, allocator) or_else scratch, true
}

// files lists the tracked paths at the end of the change. The staged
// change is tracked by the index, which is what ls-files reads.
files :: proc(t: Tree, allocator := context.allocator) -> (out: []string, ok: bool) {
	if t.rev == "" {
		return git.lines(t.root, {"ls-files"}, allocator)
	}
	return git.lines(t.root, {"ls-tree", "-r", "--name-only", t.rev}, allocator)
}

// path is where a tracked file can be read by a program that reads files.
path :: proc(t: Tree, name: string, allocator := context.allocator) -> string {
	joined, err := filepath.join({t.dir, name}, allocator)
	if err != nil {
		return name
	}
	return joined
}

// read is a tracked file's contents at the end of the change.
read :: proc(t: Tree, name: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	contents, err := os.read_entire_file_from_path(
		path(t, name, context.temp_allocator),
		allocator,
	)
	return contents, err == nil
}

// sources reads every tracked file that is text, so that a search over
// the repository is a loop over memory rather than a program run. Binary
// files are left out by the cheapest test there is: a NUL byte in the
// first kilobyte.
sources :: proc(t: Tree, allocator := context.allocator) -> (out: map[string][]byte, ok: bool) {
	tracked := files(t, context.temp_allocator) or_return
	out = make(map[string][]byte, allocator)
	for name in tracked {
		data, readable := read(t, name, allocator)
		if !readable {
			continue // A tracked path the tree cannot read is a link or gone.
		}
		head := data[:min(len(data), 1024)]
		if slice.contains(head, 0) {
			delete(data, allocator)
			continue
		}
		out[strings.clone(name, allocator)] = data
	}
	return out, true
}

// line is one line of a file at the end of the change, trimmed, or empty
// where the file or the line is not there.
line :: proc(t: Tree, name: string, number: int, allocator := context.allocator) -> string {
	if number < 1 {
		return ""
	}
	data, ok := read(t, name, context.temp_allocator)
	if !ok {
		return ""
	}
	rest := string(data)
	n := 0
	for text in strings.split_lines_iterator(&rest) {
		n += 1
		if n == number {
			return strings.clone(strings.trim_space(text), allocator)
		}
	}
	return ""
}

// exists reports whether the tree holds the path as a file.
exists :: proc(t: Tree, name: string) -> bool {
	return os.is_file(path(t, name, context.temp_allocator))
}

// ends reports the revision a range arrives at, and whether it is a range
// at all. Both A..B and A...B are reviewed as B.
ends :: proc(rev: string) -> (after: string, ranged: bool) {
	i := strings.index(rev, "..")
	if i < 0 {
		return rev, false
	}
	return strings.trim_prefix(rev[i + 2:], "."), true
}
