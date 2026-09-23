// review, the Odin reading: what a change adds, read through the language
// sidecars, and the repository's declarations it is judged against. The
// change is the staged one, or the revision range given.
//
//	review            # the staged change
//	review HEAD^..HEAD
package main

import "core:fmt"
import "core:os"

import "../change"
import "../git"
import "../tree"

main :: proc() {
	rev := os.args[1] if len(os.args) > 1 else ""
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		fmt.eprintln("review: no working directory")
		os.exit(2)
	}
	root, in_repo := git.toplevel(cwd)
	if !in_repo {
		fmt.eprintln("review: not in a git repository")
		os.exit(2)
	}
	c, gathered := change.gather(rev, root)
	if !gathered {
		fmt.eprintfln("review: git could not describe %q", rev)
		os.exit(1)
	}
	if len(c.files) == 0 {
		fmt.println("nothing to review")
		return
	}
	t, at_ok := tree.at(root, rev)
	if !at_ok {
		fmt.eprintfln("review: could not materialise %q", rev)
		os.exit(1)
	}
	defer tree.close(t)

	read_ok := change.read(&c, t)
	fmt.printfln("=== change %s: %d files, %d added lines ===", rev, len(c.files), added(c))
	for s in c.symbols {
		mark := " exported" if s.exported else ""
		fmt.printfln("symbol  %s:%d %s %s%s", s.file, s.line, s.kind, s.name, mark)
	}
	for f in c.tests {
		fmt.printfln("test    %s:%d %s", f.file, f.line, f.name)
	}
	for l in c.comments {
		fmt.printfln("comment %s:%d %s", l.file, l.line, l.text)
	}
	for name in c.uncovered {
		fmt.printfln("unread  %s", name)
	}
	declared, indexed := change.index(t)
	fmt.printfln("=== index: %d declarations ===", len(declared))
	if !read_ok || !indexed {
		fmt.eprintln("review: a sidecar did not answer")
		os.exit(1)
	}
}

added :: proc(c: change.Change) -> int {
	n := 0
	for _, lines in c.added {
		n += len(lines)
	}
	return n
}
