/*
Package change gathers the change under review — the staged change, or a
revision range — and reads what it adds: the declarations, tests and
comments on the lines the diff introduces, through the language sidecars,
and the repository's own declarations at the end of the change, which is
what new work is judged against.
*/
package change

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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

// Function is a test the change adds or touches, whole. skips is the
// line the test skips itself on, or zero, read from the body by shape.
Function :: struct {
	name:  string,
	file:  string,
	line:  int,
	body:  string,
	skips: int,
}

// Located is a comment the change adds, with the code it sits above, a
// couple of lines of it, so that a claim about behaviour can be read
// beside the behaviour.
Located :: struct {
	text:  string,
	file:  string,
	line:  int,
	below: string,
}

// Temporal is what the repository's history counts about the files the
// change touches: how many commits touch each, and which other files
// those commits also touched, nearest first.
Temporal :: struct {
	commits:  map[string]int,
	partners: map[string][]Partner,
}

// Partner is another file that history shows changing with a changed one.
Partner :: struct {
	name:   string,
	shared: int,
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
	diff:       string,
	truncated:  bool,
	// files are the paths it touches.
	files:      []string,
	// message is the commit message: empty for a staged change.
	message:    string,
	stat:       string,
	// added and removed are the diff's two sides, per file.
	added:      map[string][dynamic]Diff_Line,
	removed:    map[string][dynamic]string,
	// What the sidecars read on the added lines.
	symbols:    [dynamic]Symbol,
	tests:      [dynamic]Function,
	comments:   [dynamic]Located,
	imports:    map[string][]string,
	// uncovered are the code files no sidecar read, with a reason each.
	uncovered:  [dynamic]Gap,
	// convention is the recent commit subjects, so a check can read the
	// local habit; history is the last thousand, the word frequencies the
	// message is measured against.
	convention: []string,
	history:    []string,
	// temporal is the counted history of the files the change touches,
	// or nothing when the history says nothing.
	temporal:   Maybe(Temporal),
	// changed is how many lines the diff adds and removes, counted by git
	// over the whole change rather than the capped diff; whitespace is how
	// many of them change nothing but whitespace.
	changed:    int,
	whitespace: int,
	// index is every declaration in the repository at the end of the
	// change, kept for the checks that judge new work against it.
	index:      []Declared,
	// candidates are existing names that resemble each new one, gathered
	// by search rather than by the model; twins are the existing
	// declarations holding the same literal as a new one, the shortest
	// list worth reading.
	candidates: map[string][]string,
	twins:      map[string][]string,
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
	// The whitespace-only lines are what the diff loses when git is asked
	// to ignore whitespace; the difference is the formatting mixed in.
	count :=
		[]string{"diff", "--cached", "--numstat"} if rev == "" else []string{"diff", rev, "--numstat"}
	loose :=
		[]string{"diff", "--cached", "-w", "--numstat"} if rev == "" else []string{"diff", rev, "-w", "--numstat"}
	if plain, counted := git.run(root, count, context.temp_allocator); counted {
		if without, counted_loose := git.run(root, loose, context.temp_allocator); counted_loose {
			c.changed = count_numstat(plain)
			c.whitespace = c.changed - count_numstat(without)
		}
	}
	c.convention, _ = git.lines(root, {"log", "-12", "--format=%s"})
	c.history, _ = git.lines(root, {"log", "-1000", "--format=%s"})
	c.added, c.removed = diff_sides(c.diff)
	c.imports = make(map[string][]string)
	read_temporal(&c, root, rev)
	return c, true
}

// count_numstat sums the lines added and removed over git's --numstat
// output. A binary file's counts are dashes and count nothing.
count_numstat :: proc(out: string) -> int {
	n := 0
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) < 3 {
			continue
		}
		a, _ := strconv.parse_int(parts[0])
		b, _ := strconv.parse_int(parts[1])
		n += a + b
	}
	return n
}

// The counting window and width: the coupling is counted over the last
// thousand commits before the change, and a commit listing more than a
// hundred files is left out of the count — a sweep touching everything
// once says nothing about any pair. partner_list is the fewest-nearest
// partners kept per changed file.
temporal_window :: 1000
temporal_width  :: 100
partner_list    :: 20

// read_temporal counts, over the last thousand commits before the change,
// how often each changed file is touched by a commit that also touches
// another file. The history starts at the commit the change begins at, so
// the change under review is never counted against itself.
read_temporal :: proc(c: ^Change, root, rev: string) {
	if len(c.files) == 0 {
		return
	}
	start := ""
	switch {
	case rev == "":
	case strings.contains(rev, ".."):
		start = rev[:strings.index(rev, "..")]
	case strings.has_suffix(rev, "^"):
		start = rev
	case:
		start = strings.concatenate({rev, "^"}, context.temp_allocator)
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "log", fmt.tprintf("-%d", temporal_window), "--format=%x00", "--name-only")
	if start != "" {
		append(&args, start)
	}
	logs, ok := git.run(root, args[:], context.temp_allocator)
	if !ok {
		return // No history, or a bare first commit: nothing to count.
	}
	changed := make(map[string]bool, context.temp_allocator)
	for f in c.files {
		changed[f] = true
	}
	commits := make(map[string]int)
	pairs := make(map[string]map[string]int, context.temp_allocator)
	for chunk in strings.split(logs, "\x00", context.temp_allocator) {
		files := make([dynamic]string, context.temp_allocator)
		rest := chunk
		for line in strings.split_lines_iterator(&rest) {
			if trimmed := strings.trim_space(line); trimmed != "" {
				append(&files, trimmed)
			}
		}
		if len(files) > temporal_width {
			continue
		}
		for f in files {
			commits[strings.clone(f)] += 1
		}
		for f in files {
			if !changed[f] {
				continue
			}
			if f not_in pairs {
				pairs[f] = make(map[string]int, context.temp_allocator)
			}
			counts := &pairs[f]
			for g in files {
				if g != f {
					counts[g] += 1
				}
			}
		}
	}
	t := Temporal {
		commits  = commits,
		partners = make(map[string][]Partner),
	}
	Named :: struct {
		name: string,
		j:    f64,
	}
	for f, ps in pairs {
		list := make([dynamic]Named, context.temp_allocator)
		for name, shared in ps {
			joint := commits[f] + commits[name] - shared
			if joint <= 0 {
				continue
			}
			append(&list, Named{name, f64(shared) / f64(joint)})
		}
		slice.sort_by_cmp(list[:], proc(a, b: Named) -> slice.Ordering {
			if a.j != b.j {
				return .Less if a.j > b.j else .Greater
			}
			return .Less if a.name < b.name else (.Greater if a.name > b.name else .Equal)
		})
		partners := make([dynamic]Partner)
		for e in list {
			if len(partners) == partner_list {
				break
			}
			// A partner the tree no longer holds is history's partner, not
			// this change's.
			if remaining(root, rev, e.name) {
				append(&partners, Partner{strings.clone(e.name), ps[e.name]})
			}
		}
		if len(partners) > 0 {
			t.partners[strings.clone(f)] = partners[:]
		}
	}
	if len(t.partners) > 0 {
		c.temporal = t
	}
}

// remaining reports whether a partner path is still a file at the end of
// the change.
remaining :: proc(root, rev, name: string) -> bool {
	after, ranged := tree.ends(rev)
	if !ranged {
		return os.is_file(filepath.join({root, name}, context.temp_allocator) or_else name)
	}
	_, ok := git.run(
		root,
		{"cat-file", "-e", strings.concatenate({after, ":", name}, context.temp_allocator)},
		context.temp_allocator,
	)
	return ok
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
		if _, covered := frontend.sidecar_for(name); covered || !tree.exists(t, name) {
			continue
		}
		// A language no parser covers still has its comments read, by
		// the prefixes the C-family shares; the jobs that need
		// declarations or test bodies are named as unread for it.
		if heuristic_covers(name) {
			if source, readable := tree.read(t, name, context.temp_allocator); readable {
				append(&c.comments, ..comment_prose(source, name, c.added[name])[:])
			}
			append(
				&c.uncovered,
				Gap{name, "no duplication, namer parser"},
				Gap{name, "no tests parser"},
			)
			continue
		}
		// A file no reader could plausibly exist for — prose, data,
		// configuration — is not a promise the review broke; a code file
		// with no reader is, because a job that would have read it read
		// nothing.
		if is_code_file(name) {
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
	annotate(c, t)
	return ok
}

// annotate adds to what the sidecars read the parts every language
// shares: the code below each comment, and the line a test skips itself
// on. Both are read by shape from the source.
annotate :: proc(c: ^Change, t: tree.Tree) {
	lines := make(map[string][]string, context.temp_allocator)
	for &comment in c.comments {
		if comment.file not_in lines {
			source, readable := tree.read(t, comment.file, context.temp_allocator)
			lines[comment.file] =
				strings.split_lines(string(source), context.temp_allocator) if readable else nil
		}
		comment.below = code_below(lines[comment.file], comment.line)
	}
	for &test in c.tests {
		test.skips = skip_line(test)
	}
}

// below_lines is how much code a comment is shown beside.
below_lines :: 2

// code_below is the code that follows a comment: the first lines after it
// that are neither blank nor comment, up to below_lines of them.
code_below :: proc(lines: []string, comment: int, allocator := context.allocator) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for i := comment; i < len(lines) && len(out) < below_lines; i += 1 {
		trimmed := strings.trim_space(lines[i])
		if trimmed == "" || is_comment_line(trimmed) {
			if len(out) > 0 {
				break
			}
			continue
		}
		append(&out, trimmed)
	}
	return strings.join(out[:], "\n", allocator)
}

// is_comment_line is whether a trimmed line is a comment by the shapes
// the tool's languages share.
is_comment_line :: proc(trimmed: string) -> bool {
	if strings.has_prefix(trimmed, "//") ||
	   strings.has_prefix(trimmed, "/*") ||
	   strings.has_prefix(trimmed, "*") {
		return true
	}
	return strings.has_prefix(trimmed, "#") && !strings.has_prefix(trimmed, "#!")
}

// skip_line is the line a test skips itself on, or zero.
skip_line :: proc(t: Function) -> int {
	rest := t.body
	i := 0
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		for shape in ([]string{"t.Skip(", "t.Skipf(", "t.SkipNow(", "test.skip(", "it.skip(", "describe.skip(", "this.skip(", "testing.skip(", "t.skip(", "pytest.skip(", "pytest.mark.skip", "self.skipTest(", "unittest.skip"}) {
			if strings.contains(trimmed, shape) {
				return t.line + i
			}
		}
		i += 1
	}
	return 0
}

// heuristic_covers reports the languages whose comment shape is known
// without a parser. Prose-only formats are left out: their text is not a
// comment.
heuristic_covers :: proc(path: string) -> bool {
	for ext in ([]string{".py", ".rb", ".rs", ".c", ".h", ".cc", ".cpp", ".hpp", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".lua", ".zig", ".swift", ".kt", ".java", ".php", ".scala", ".cs"}) {
		if strings.has_suffix(path, ext) {
			return true
		}
	}
	return false
}

// comment_prose lifts the comment lines among the added ones out of a
// source file by the prefixes the C-family shares: // and # for line
// comments, an open /* kept whole until its close. The shebang is not a
// comment.
comment_prose :: proc(
	source: []byte,
	name: string,
	touched: [dynamic]Diff_Line,
	allocator := context.allocator,
) -> [dynamic]Located {
	out := make([dynamic]Located, allocator)
	if len(touched) == 0 {
		return out
	}
	is_touched := make(map[int]bool, context.temp_allocator)
	for l in touched {
		is_touched[l.line] = true
	}
	in_block := false
	rest := string(source)
	number := 0
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		trimmed := strings.trim_space(line)
		switch {
		case in_block:
			if is_touched[number] {
				t := strings.trim_suffix(trimmed, "*/")
				t = strings.trim_space(strings.trim_prefix(t, "*"))
				if t != "" {
					append(
						&out,
						Located{text = strings.clone(t, allocator), file = name, line = number},
					)
				}
			}
			if strings.contains(trimmed, "*/") {
				in_block = false
			}
		case strings.has_prefix(trimmed, "/*"):
			t := trimmed[2:]
			if end := strings.index(t, "*/"); end >= 0 {
				t = t[:end]
			} else {
				in_block = true
			}
			if is_touched[number] && strings.trim_space(t) != "" {
				text := strings.trim_space(strings.trim_prefix(strings.trim_space(t), "*"))
				append(
					&out,
					Located{text = strings.clone(text, allocator), file = name, line = number},
				)
			}
		case strings.has_prefix(trimmed, "//"):
			if is_touched[number] {
				append(
					&out,
					Located {
						text = strings.clone(
							strings.trim_space(strings.trim_prefix(trimmed, "//")),
							allocator,
						),
						file = name,
						line = number,
					},
				)
			}
		case strings.has_prefix(trimmed, "#") && !strings.has_prefix(trimmed, "#!"):
			if is_touched[number] {
				append(
					&out,
					Located {
						text = strings.clone(
							strings.trim_space(strings.trim_prefix(trimmed, "#")),
							allocator,
						),
						file = name,
						line = number,
					},
				)
			}
		}
	}
	return out
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
						body = body_of(decl, lines),
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
			symbol.body = body_of(decl, lines)
		}
		append(&c.symbols, symbol)
	}
	// Go's sidecar reads comments with its parser; every other language's
	// are read by shape, the same way for a parsed file and an unparsed
	// one.
	if s, _ := frontend.sidecar_for(name); s == .Go {
		for comment in file.comments {
			if touched[comment.line] {
				append(
					&c.comments,
					Located{text = strings.clone(comment.text), file = name, line = comment.line},
				)
			}
		}
	} else {
		append(&c.comments, ..comment_prose(source, name, added)[:])
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
					entry.body = body_of(decl, lines)
				}
				append(&declared, entry)
			}
		}
	}
	return declared[:], ok
}

// body_of is a declaration's whole text: the reader's own match where it
// has one, else the file's lines from its first to its last.
body_of :: proc(decl: frontend.Decl, lines: []string, allocator := context.allocator) -> string {
	if decl.body != "" {
		return strings.clone(decl.body, allocator)
	}
	return text(lines, decl.line, decl.end_line, allocator)
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
