/*
Package analyser runs the compilers and analysers a repository's languages
already have, which are the deterministic checks with the most to say.
What review decides is which of their findings belong to the change: an
error anywhere in a unit the change touched is the change's to answer,
because the tree does not compile until it is; a warning is the change's
only where it lands on a line the change added. Each is run with its
strictest settings and asked for JSON, on the tree the change arrives at.
*/
package analyser

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:time"
import "jm:sh"

import "../change"
import "../finding"
import "../tree"

// timeout_seconds bounds one analyser's run. A cold first analysis of a
// large module can take minutes; past this the analyser says nothing
// rather than holding the review.
timeout_seconds :: 300

// timeout_seconds_override is the bound a test lowers; zero means the
// constant above.
timeout_seconds_override: int

// Diagnostic is one thing an analyser said, located in the tree. A fault
// is a compile error — the tree does not build — rather than an
// analyser's opinion about code that does.
Diagnostic :: struct {
	file:     string,
	line:     int,
	code:     string,
	message:  string,
	severity: finding.Severity,
	fault:    bool,
}

// Analyser is one compiler or analyser, run over the units the change's
// files belong to. name prefixes its rule ids: name/code. covers is
// whether a path is one of its language, given the shell dialect the
// change settled for it, which is empty for everything that is not a
// script. ready is whether it can run in
// this tree, with the reason it cannot, told once. run analyses the units
// the files belong to and returns what it found with paths relative to
// the tree, or why it could not. in_place is whether it needs the working
// tree's surroundings — installed packages, a node_modules — and so cannot
// read a range's materialised tree.
Analyser :: struct {
	name:     string,
	covers:   proc(path, shell: string) -> bool,
	ready:    proc(tree: string) -> (ok: bool, why: string),
	run:      proc(tree, root: string, files: []string) -> (found: []Diagnostic, err: string),
	in_place: bool,
}

// all is the compilers and analysers review knows how to run, in the
// order their findings are worth having.
all :: proc(allocator := context.temp_allocator) -> []Analyser {
	list := make([]Analyser, 10, allocator)
	list[0], list[1], list[2] = go_build, go_vet, staticcheck
	list[3], list[4], list[5] = odin_check, tsc, ruff
	list[6], list[7], list[8] = mypy, cargo, semgrep
	list[9] = shellcheck
	return list
}

// check runs every analyser that covers a changed file and can run, and
// keeps the findings that belong to the change. What could not run is
// said on stderr.
check :: proc(
	c: ^change.Change,
	t: tree.Tree,
	ranged: bool,
	analysers := []Analyser{},
	allocator := context.allocator,
) -> []finding.Finding {
	context.allocator = allocator
	out := make([dynamic]finding.Finding)
	changed := make(map[string]bool, context.temp_allocator)
	for f in c.files {
		changed[f] = true
	}
	which := analysers if len(analysers) > 0 else all()
	for a in which {
		files := make([dynamic]string, context.temp_allocator)
		for f in c.files {
			if a.covers(f, change.shell_for(c, f)) && tree.exists(t, f) {
				append(&files, f)
			}
		}
		if len(files) == 0 {
			continue
		}
		if ok, why := a.ready(t.dir); !ok {
			if why != "" {
				fmt.eprintfln("skipping %s: %s", a.name, why)
			}
			continue
		}
		if a.in_place && ranged {
			fmt.eprintfln(
				"skipping %s: it reads the working tree, and the change is a range",
				a.name,
			)
			continue
		}
		found, err := a.run(t.dir, t.root, files[:])
		if err != "" {
			fmt.eprintfln("skipping %s: %s", a.name, err)
			continue
		}
		seen := make(map[string]bool, context.temp_allocator)
		for d in found {
			if d.file == "" || d.line == 0 {
				continue
			}
			// A fault is the change's wherever it lands: the unit it
			// touched no longer compiles. An opinion is the change's only
			// on a line it added.
			if !d.fault && (!changed[d.file] || !added_line(c, d.file, d.line)) {
				continue
			}
			key := fmt.tprintf("%s:%d:%s:%s", d.file, d.line, d.code, d.message)
			if seen[key] {
				continue
			}
			seen[strings.clone(key, context.temp_allocator)] = true
			rule := a.name if d.code == "" else fmt.aprintf("%s/%s", a.name, d.code)
			append(
				&out,
				finding.Finding {
					job = "static",
					rule = rule,
					severity = d.severity,
					file = strings.clone(d.file),
					line = d.line,
					message = strings.clone(d.message),
					verified = true,
				},
			)
		}
	}
	return out[:]
}

// added_line is whether the diff added the line of the file.
added_line :: proc(c: ^change.Change, file: string, line: int) -> bool {
	lines := c.added[file]
	for l in lines {
		if l.line == line {
			return true
		}
	}
	return false
}

// execute works one command in the tree and returns its output. A command
// that reports findings by exiting non-zero is not a failed run: its
// stdout is the answer, and only an empty stdout with a non-zero exit is a
// fault. A run past the timeout is a fault of its own.
execute :: proc(
	dir: string,
	name: string,
	args: []string,
	allocator := context.allocator,
) -> (
	stdout: string,
	err: string,
) {
	out, errs, e := execute_both(dir, name, args, allocator)
	if e != "" && len(out) == 0 {
		return "", e if errs == "" else e
	}
	return out, ""
}

// execute_both works one command and returns both streams: the Odin
// compiler writes its JSON to stderr, and a tool that fails before it
// starts says why there too.
execute_both :: proc(
	dir: string,
	name: string,
	args: []string,
	allocator := context.allocator,
) -> (
	stdout, stderr: string,
	err: string,
) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, name)
	append(&argv, ..args)
	bound := timeout_seconds if timeout_seconds_override == 0 else timeout_seconds_override
	r := sh.exec(argv[:], {dir = dir, timeout = time.Duration(bound) * time.Second}, allocator)
	if r.err != nil {
		return "", "", fmt.aprintf("%s: %s", name, os.error_string(r.err), allocator = allocator)
	}
	if r.timed_out {
		return r.stdout, r.stderr, fmt.aprintf("a run past %d seconds is not waited for", bound, allocator = allocator)
	}
	if !r.ok {
		detail := strings.trim_space(r.stderr)
		if detail == "" {
			detail = fmt.tprintf("exit %d", r.code)
		}
		return r.stdout, r.stderr, fmt.aprintf("%s: %s", name, tail(detail, 200), allocator = allocator)
	}
	return r.stdout, r.stderr, ""
}

// on_path is a ready that needs only the binary.
on_path :: proc(binary: string) -> bool {
	_, found := sh.which(binary, context.temp_allocator)
	return found
}

// relative is a path relative to the tree, where it lies inside it.
relative :: proc(tree_dir, path: string) -> string {
	if strings.has_prefix(path, tree_dir) &&
	   len(path) > len(tree_dir) &&
	   path[len(tree_dir)] == '/' {
		return path[len(tree_dir) + 1:]
	}
	if strings.has_prefix(path, "./") {
		return path[2:]
	}
	return path
}

// join is a path under a directory.
join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	return filepath.join({dir, name}, allocator) or_else name
}

// dir_of is the directory a path sits in, "." at the top.
dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[:i]
	}
	return "."
}

// nearest is the path, relative to the tree, of the first file called
// name in dir or a directory above it, or empty.
nearest :: proc(tree_dir, dir, name: string) -> string {
	d := dir
	for {
		candidate :=
			name if d == "." || d == "" else strings.concatenate({d, "/", name}, context.temp_allocator)
		if os.is_file(join(tree_dir, candidate)) {
			return candidate
		}
		if d == "." || d == "" || d == "/" {
			return ""
		}
		d = dir_of(d)
	}
}

// tail is the last few bytes of a longer text, for an error message.
tail :: proc(s: string, n: int) -> string {
	trimmed := strings.trim_space(s)
	if len(trimmed) <= n {
		return trimmed
	}
	return strings.concatenate({"…", trimmed[len(trimmed) - n:]}, context.temp_allocator)
}

// position reads file and line out of file:line:col: message, as the Go
// tools print it.
position :: proc(text: string) -> (file: string, line: int, message: string, ok: bool) {
	re, err := regex.create(
		`^(.+?):(\d+)(?::(\d+))?: (.*)$`,
		{},
		context.temp_allocator,
		context.temp_allocator,
	)
	if err != nil {
		return
	}
	cap, matched := regex.match(re, text, context.temp_allocator)
	if !matched {
		return
	}
	line, _ = strconv.parse_int(cap.groups[2])
	return cap.groups[1], line, cap.groups[4], true
}

// split_json_objects cuts a stream of top-level JSON objects, with
// anything between them — vet's # comment lines, prose about a failed
// package — left out. An object opens only at the start of a line, as vet
// writes them, so a brace in the prose opens nothing.
split_json_objects :: proc(out: string, allocator := context.allocator) -> []string {
	chunks := make([dynamic]string, allocator)
	depth, start := 0, -1
	in_string, line_start := false, true
	i := 0
	for i < len(out) {
		c := out[i]
		switch {
		case in_string:
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
		case depth > 0 && c == '"':
			in_string = true
		case c == '{' && (depth > 0 || line_start):
			if depth == 0 {
				start = i
			}
			depth += 1
		case c == '}' && depth > 0:
			depth -= 1
			if depth == 0 {
				append(&chunks, out[start:i + 1])
				start = -1
			}
		}
		line_start = c == '\n'
		i += 1
	}
	return chunks[:]
}

// lines_of is a text's lines, for the tools that write one JSON object
// per line.
lines_of :: proc(text: string, allocator := context.temp_allocator) -> []string {
	return strings.split_lines(text, allocator)
}
