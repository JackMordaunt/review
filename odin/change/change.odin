/*
Package change gathers the change under review — the staged change, or a
revision range — and reads what it adds: the declarations, tests and
comments on the lines the diff introduces, through the language sidecars,
and the repository's own declarations at the end of the change, which is
what new work is judged against.
*/
package change

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "../frontend"
import "../git"
import "../tree"

// Symbol is a declaration the change adds.
Symbol :: struct {
	name:      string,
	kind:      string,
	doc:       string,
	file:      string,
	line:      int,
	exported:  bool,
	signature: string,
	body:      string,
	pkg:       string,
}

// Function is a test the change adds or touches, whole.
Function :: struct {
	name: string,
	file: string,
	line: int,
	body: string,
}

// Located is a comment the change adds.
Located :: struct {
	text: string,
	file: string,
	line: int,
}

// Declared is one declaration somewhere in the repository, which a new
// name might turn out to duplicate.
Declared :: struct {
	name: string,
	kind: string,
	file: string,
	line: int,
	text: string,
	body: string,
}

// Gap is a file the deterministic side could not read, and why.
Gap :: struct {
	file:   string `json:"file"`,
	reason: string `json:"reason"`,
}

// Diff_Line is one added line and the number it lands on.
Diff_Line :: struct {
	line: int,
	text: string,
}

// Change is what is under review.
Change :: struct {
	// diff is the change itself, capped at max_diff.
	diff:      string,
	truncated: bool,
	// files are the paths it touches.
	files:     []string,
	// message is the commit message: empty for a staged change.
	message:   string,
	stat:      string,
	// added and removed are the diff's two sides, per file.
	added:     map[string][dynamic]Diff_Line,
	removed:   map[string][dynamic]string,
	// What the sidecars read on the added lines.
	symbols:   [dynamic]Symbol,
	tests:     [dynamic]Function,
	comments:  [dynamic]Located,
	imports:   map[string][]string,
	// uncovered are the code files no sidecar read, with a reason each.
	uncovered: [dynamic]Gap,
}

max_diff :: 60000

// gather collects the change at a revision range, or the staged change
// when the range is empty. Everything is allocated from allocator.
gather :: proc(rev, root: string, allocator := context.allocator) -> (c: Change, ok: bool) {
	context.allocator = allocator
	diff_args, name_args, stat_args: []string
	if rev == "" {
		diff_args = {"diff", "--cached", "-U3", "--src-prefix=a/", "--dst-prefix=b/"}
		name_args = {"diff", "--cached", "--name-only"}
		stat_args = {"diff", "--cached", "--stat"}
	} else {
		diff_args = {"diff", rev, "-U3", "--src-prefix=a/", "--dst-prefix=b/"}
		name_args = {"diff", rev, "--name-only"}
		stat_args = {"diff", rev, "--stat"}
	}
	c.diff = git.run(root, diff_args) or_return
	if len(c.diff) > max_diff {
		c.diff = strings.concatenate({c.diff[:max_diff], "\n… diff truncated\n"})
		c.truncated = true
	}
	c.files = git.lines(root, name_args) or_return
	c.stat = git.run(root, stat_args) or_return
	if rev != "" {
		c.message, _ = git.run(root, {"log", "-1", "--format=%B", strings.trim_suffix(rev, "^")})
	}
	c.added, c.removed = diff_sides(c.diff)
	c.imports = make(map[string][]string)
	return c, true
}

// diff_sides splits a diff into the added and removed lines of each file.
// The header lines are read wherever they sit, as they sit between hunks;
// content is read only inside a hunk, so that a removed line beginning
// "+++ " is not mistaken for the header it resembles.
diff_sides :: proc(
	diff: string,
	allocator := context.allocator,
) -> (
	added: map[string][dynamic]Diff_Line,
	removed: map[string][dynamic]string,
) {
	context.allocator = allocator
	added = make(map[string][dynamic]Diff_Line)
	removed = make(map[string][dynamic]string)
	added_file, removed_file: string
	line: int
	in_hunk: bool
	for text in strings.split_lines(diff, context.temp_allocator) {
		switch {
		case strings.has_prefix(text, "+++ "):
			added_file = side(text[4:], "b/")
			in_hunk = false
		case strings.has_prefix(text, "--- "):
			removed_file = side(text[4:], "a/")
			in_hunk = false
		case strings.has_prefix(text, "\\ "):
		// The no-newline marker annotates the line above it.
		case strings.has_prefix(text, "@@ "):
			if start, found := hunk_start(text); found {
				in_hunk = true
				line = start
			}
		case strings.has_prefix(text, "+") && in_hunk:
			if added_file != "" {
				lines := added[added_file]
				append(&lines, Diff_Line{line, strings.clone(text[1:])})
				added[added_file] = lines
			}
			line += 1
		case strings.has_prefix(text, "-") && in_hunk:
			if removed_file != "" {
				lines := removed[removed_file]
				append(&lines, strings.clone(text[1:]))
				removed[removed_file] = lines
			}
		case:
			if in_hunk {
				line += 1
			}
		}
	}
	return
}

// hunk_start reads the line a hunk's added side begins on, out of its
// "@@ -a,b +c,d @@" header.
hunk_start :: proc(text: string) -> (line: int, ok: bool) {
	i := strings.index(text, " +")
	if i < 0 {
		return 0, false
	}
	rest := text[i + 2:]
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
		end += 1
	}
	if end == 0 {
		return 0, false
	}
	return strconv.parse_int(rest[:end])
}

// side strips a diff's prefix from a header path, and a deletion's
// /dev/null with it.
side :: proc(path, prefix: string) -> string {
	stripped := strings.trim_prefix(path, prefix)
	if stripped == "/dev/null" {
		return ""
	}
	return strings.clone(stripped)
}

// read fills the change's symbols, tests, comments and imports from the
// sidecars, over the files at the end of the change. Only what the diff
// added is reported, so a job sees new work rather than the file it
// landed in: a declaration is new when its line is, a test when any line
// of it is, a comment when it sits on an added line.
read :: proc(c: ^Change, t: tree.Tree, allocator := context.allocator) -> bool {
	context.allocator = allocator
	ok := true
	for name in c.files {
		// A file no reader could plausibly exist for — prose, data,
		// configuration — is not a promise the review broke; a code file
		// with no reader is, because a job that would have read it read
		// nothing.
		if _, covered := frontend.sidecar_for(name);
		   !covered && is_code_file(name) && tree.exists(t, name) {
			append(&c.uncovered, Gap{name, "no reader"})
		}
	}
	for sidecar in frontend.Sidecar {
		names := make([dynamic]string, context.temp_allocator)
		for name in c.files {
			if s, covered := frontend.sidecar_for(name);
			   covered && s == sidecar && tree.exists(t, name) {
				append(&names, name)
			}
		}
		if len(names) == 0 {
			continue
		}
		answers, err := scan(sidecar, t, names[:], context.temp_allocator)
		if err != .None {
			why := fmt.aprintf("%s: %s", frontend.binary(sidecar), scan_error(err))
			for name in names {
				append(&c.uncovered, Gap{name, why})
			}
			ok = false
			continue
		}
		for name in names {
			file, answered := answers[name]
			if !answered {
				append(&c.uncovered, Gap{name, "no answer from the sidecar"})
				continue
			}
			if file.error != "" {
				append(&c.uncovered, Gap{name, strings.clone(file.error)})
				continue
			}
			read_file(c, t, name, file)
		}
	}
	return ok
}

// read_file keeps what one file's answer says about the added lines.
read_file :: proc(c: ^Change, t: tree.Tree, name: string, file: frontend.File) {
	source, readable := tree.read(t, name, context.temp_allocator)
	if !readable {
		return
	}
	lines := strings.split_lines(string(source), context.temp_allocator)
	touched := make(map[int]bool, context.temp_allocator)
	// The lookup is bound before the loop: ranging over a map index with
	// a missing key reads through a nil entry.
	added := c.added[name]
	for l in added {
		touched[l.line] = true
	}
	c.imports[name] = clone_all(file.imports)
	for decl in file.decls {
		if decl.kind == "field" {
			continue
		}
		if decl.test {
			if touched_between(touched, decl.line, decl.end_line) {
				append(
					&c.tests,
					Function {
						name = strings.clone(decl.name),
						file = name,
						line = decl.line,
						body = text(lines, decl.line, decl.end_line),
					},
				)
			}
			continue
		}
		if !touched[decl.line] {
			continue
		}
		symbol := Symbol {
			name      = strings.clone(decl.name),
			kind      = strings.clone(decl.kind),
			doc       = strings.clone(decl.doc),
			file      = name,
			line      = decl.line,
			exported  = decl.exported,
			signature = strings.clone(decl.text),
			pkg       = strings.clone(file.pkg),
		}
		if decl.kind == "func" {
			symbol.body = text(lines, decl.line, decl.end_line)
		}
		append(&c.symbols, symbol)
	}
	for comment in file.comments {
		if touched[comment.line] {
			append(
				&c.comments,
				Located{text = strings.clone(comment.text), file = name, line = comment.line},
			)
		}
	}
}

// index is every declaration in the repository at the end of the change,
// tests and locals left out: a test is not a fact with two owners, and a
// local is nobody else's to duplicate.
index :: proc(t: tree.Tree, allocator := context.allocator) -> (out: []Declared, ok: bool) {
	context.allocator = allocator
	tracked := tree.files(t, context.temp_allocator) or_return
	declared := make([dynamic]Declared)
	ok = true
	for sidecar in frontend.Sidecar {
		names := make([dynamic]string, context.temp_allocator)
		for name in tracked {
			if s, covered := frontend.sidecar_for(name);
			   covered && s == sidecar && !is_test_file(name) {
				append(&names, name)
			}
		}
		if len(names) == 0 {
			continue
		}
		answers, err := scan(sidecar, t, names[:], context.temp_allocator)
		if err != .None {
			ok = false
			continue
		}
		for name in names {
			file, answered := answers[name]
			if !answered || file.error != "" {
				continue
			}
			lines: []string
			if source, readable := tree.read(t, name, context.temp_allocator); readable {
				lines = strings.split_lines(string(source), context.temp_allocator)
			}
			for decl in file.decls {
				if decl.test || decl.local {
					continue
				}
				entry := Declared {
					name = strings.clone(decl.name),
					kind = strings.clone(decl.kind),
					file = name,
					line = decl.line,
					text = strings.clone(decl.text),
				}
				if decl.kind == "func" {
					entry.body = text(lines, decl.line, decl.end_line)
				}
				append(&declared, entry)
			}
		}
	}
	return declared[:], ok
}

// scan asks a sidecar about tracked files, handing it their paths in the
// tree, and returns each answer under the tracked name it was asked for.
scan :: proc(
	sidecar: frontend.Sidecar,
	t: tree.Tree,
	names: []string,
	allocator := context.allocator,
) -> (
	answers: map[string]frontend.File,
	err: frontend.Scan_Error,
) {
	paths := make([]string, len(names), allocator)
	by_path := make(map[string]string, allocator)
	for name, i in names {
		paths[i] = tree.path(t, name, allocator)
		by_path[paths[i]] = name
	}
	out := frontend.scan(sidecar, paths, allocator) or_return
	answers = make(map[string]frontend.File, allocator)
	for file in out.files {
		if name, known := by_path[file.name]; known {
			answers[name] = file
		}
	}
	return answers, .None
}

// scan_error says what a sidecar failure was.
scan_error :: proc(err: frontend.Scan_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Not_Installed:
		return "not on the path"
	case .Failed:
		return "gave no answer"
	case .Unreadable:
		return "gave an answer that is not its JSON"
	}
	return ""
}

// is_code_file reports a file a reader could plausibly exist for: not
// prose, data, configuration or the files a repository keeps for git.
is_code_file :: proc(path: string) -> bool {
	base := filepath.base(path)
	switch base {
	case ".gitignore",
	     ".gitattributes",
	     ".gitmodules",
	     ".editorconfig",
	     "Makefile",
	     "Dockerfile",
	     "LICENSE",
	     "CODEOWNERS":
		return false
	}
	for ext in ([]string{".md", ".mdx", ".txt", ".rst", ".adoc", ".json", ".yaml", ".yml", ".toml", ".lock", ".sum", ".mod", ".html", ".htm", ".css", ".svg", ".xml"}) {
		if strings.has_suffix(base, ext) {
			return false
		}
	}
	return true
}

// is_test_file reports a file the test runner reads, in Go's habit.
is_test_file :: proc(name: string) -> bool {
	return strings.has_suffix(name, "_test.go")
}

touched_between :: proc(touched: map[int]bool, from, to: int) -> bool {
	for line in from ..= to {
		if touched[line] {
			return true
		}
	}
	return false
}

// text is the lines from one number to another, inclusive, or nothing
// when the range falls outside the file.
text :: proc(lines: []string, from, to: int, allocator := context.allocator) -> string {
	if from < 1 || to > len(lines) || to < from {
		return ""
	}
	return strings.join(lines[from - 1:to], "\n", allocator)
}

clone_all :: proc(items: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(items), allocator)
	for item, i in items {
		out[i] = strings.clone(item, allocator)
	}
	return out
}
