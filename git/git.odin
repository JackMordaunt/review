/*
Package git asks the repository questions through the git program, which is
the one reader of a repository worth trusting. Every answer is a string;
a failed ask is reported as not ok, with git's own words on stderr kept for
the caller that wants them.
*/
package git

import "core:strings"
import "jm:sh"

// run asks git, in root, and returns what it printed with trailing
// whitespace removed.
run :: proc(
	root: string,
	args: []string,
	allocator := context.allocator,
) -> (
	out: string,
	ok: bool,
) {
	argv := make([]string, len(args) + 1, context.temp_allocator)
	argv[0] = "git"
	copy(argv[1:], args)
	r := sh.exec(argv, {dir = root}, allocator)
	if !r.ok {
		return r.stderr, false
	}
	return strings.trim_right_space(r.stdout), true
}

// raw asks git and returns what it printed as it printed it, trailing
// newlines kept: a diff, a stat or a message rendered into a prompt has
// to be byte for byte what the Go tool renders.
raw :: proc(
	root: string,
	args: []string,
	allocator := context.allocator,
) -> (
	out: string,
	ok: bool,
) {
	argv := make([]string, len(args) + 1, context.temp_allocator)
	argv[0] = "git"
	copy(argv[1:], args)
	r := sh.exec(argv, {dir = root}, allocator)
	if !r.ok {
		return r.stderr, false
	}
	return r.stdout, true
}

// lines is run, split into lines, empty ones dropped.
lines :: proc(
	root: string,
	args: []string,
	allocator := context.allocator,
) -> (
	out: []string,
	ok: bool,
) {
	text := run(root, args, context.temp_allocator) or_return
	kept := make([dynamic]string, allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if len(trimmed) > 0 {
			append(&kept, strings.clone(trimmed, allocator))
		}
	}
	return kept[:], true
}

// toplevel is the repository a directory sits in.
toplevel :: proc(dir: string, allocator := context.allocator) -> (root: string, ok: bool) {
	return run(dir, {"rev-parse", "--show-toplevel"}, allocator)
}
