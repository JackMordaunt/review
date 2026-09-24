/*
Package job is the narrow readings a model is asked for. Each is given the
part of the change it needs and nothing else: a job that reads less is
cheaper, and harder to distract into reporting something another job
owns. The criteria a job judges against are the thing to tune when it
reports the wrong things, and they travel with the binary.
*/
package job

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:text/regex"

import "../change"
import "../check"
import "../finding"
import "../txt"

// Job is one reading. subject renders the part of the change it reads;
// an empty subject means there is nothing here for it and the job is
// skipped. splittable is whether the subject can be read file by file: a
// subject over the packet cap is then asked in parts.
Job :: struct {
	name:       string,
	criteria:   string,
	subject:    proc(c: ^change.Change, allocator: runtime.Allocator) -> string,
	splittable: bool,
}

// all is the readings, in the order their findings are worth having.
all :: proc(allocator := context.temp_allocator) -> []Job {
	jobs := make([]Job, 5, allocator)
	jobs[0] = Job {
		"duplication",
		#load("../criteria/duplication.md", string),
		duplication_subject,
		true,
	}
	jobs[1] = Job{"tests", #load("../criteria/tests.md", string), tests_subject, true}
	jobs[2] = Job{"namer", #load("../criteria/namer.md", string), namer_subject, true}
	jobs[3] = Job{"claims", #load("../criteria/claims.md", string), claims_subject, true}
	jobs[4] = Job{"hygiene", #load("../criteria/hygiene.md", string), hygiene_subject, false}
	return jobs
}

// chosen is the jobs named, comma separated, or all of them.
chosen :: proc(only: string, allocator := context.temp_allocator) -> (jobs: []Job, err: string) {
	if strings.trim_space(only) == "" {
		return all(allocator), ""
	}
	picked := make([dynamic]Job, allocator)
	for name in strings.split(only, ",", context.temp_allocator) {
		want := strings.trim_space(name)
		found := false
		for j in all(allocator) {
			if j.name == want {
				append(&picked, j)
				found = true
			}
		}
		if !found {
			return nil, fmt.aprintf(
				"no job called %q; the jobs are claims, duplication, hygiene, namer, tests",
				want,
				allocator = allocator,
			)
		}
	}
	return picked[:], ""
}

// rules reads the ids a job may cite out of its own criteria: the bullets
// opening with a backticked id.
rules :: proc(criteria: string, allocator := context.temp_allocator) -> map[string]bool {
	out := make(map[string]bool, allocator)
	rest := criteria
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "- `") {
			continue
		}
		end := strings.index_byte(line[3:], '`')
		if end < 0 {
			continue
		}
		id := line[3:3 + end]
		valid := len(id) > 0
		for i in 0 ..< len(id) {
			c := id[i]
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
				valid = false
			}
		}
		if valid {
			out[id] = true
		}
	}
	return out
}

namer_subject :: proc(c: ^change.Change, allocator: runtime.Allocator) -> string {
	if len(c.symbols) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Names this change adds or renames:\n\n")
	for s in c.symbols {
		fmt.sbprintf(&b, "%s:%d  %s %s", s.file, s.line, s.kind, s.name)
		if s.exported {
			strings.write_string(&b, "  (exported)")
		}
		strings.write_string(&b, "\n")
		if s.signature != "" {
			fmt.sbprintf(&b, "    %s\n", s.signature)
		}
		if s.doc != "" {
			fmt.sbprintf(&b, "    doc: %s\n", check.first_line(s.doc, context.temp_allocator))
		}
		if near := c.candidates[s.name]; len(near) > 0 {
			fmt.sbprintf(
				&b,
				"    names already in this repository: %s\n",
				strings.join(near[:min(len(near), 6)], "; ", context.temp_allocator),
			)
		}
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

duplication_subject :: proc(c: ^change.Change, allocator: runtime.Allocator) -> string {
	if len(c.symbols) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	// The pairs holding the same literal go first and alone. Buried among
	// the resemblances a reading finds one of them and stops.
	if twinned := twins(c, context.temp_allocator); twinned != "" {
		strings.write_string(
			&b,
			"Declarations this change adds that hold a value already declared elsewhere.\n",
		)
		strings.write_string(&b, "Judge every pair on this list.\n\n")
		strings.write_string(&b, twinned)
		strings.write_string(&b, "\n")
	}
	strings.write_string(
		&b,
		"Each name the change adds, with existing declarations found by searching for its words.\n\n",
	)
	for s in c.symbols {
		fmt.sbprintf(&b, "NEW  %s:%d  %s %s\n", s.file, s.line, s.kind, s.name)
		if s.signature != "" {
			fmt.sbprintf(&b, "     %s\n", s.signature)
		}
		if s.doc != "" {
			fmt.sbprintf(&b, "     doc: %s\n", check.first_line(s.doc, context.temp_allocator))
		}
		candidates := c.candidates[s.name]
		if len(candidates) == 0 {
			strings.write_string(&b, "     candidates: none found\n\n")
			continue
		}
		strings.write_string(&b, "     candidates:\n")
		for line in candidates {
			fmt.sbprintf(&b, "       %s\n", line)
		}
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

// twins renders the declarations whose value already exists, in the
// order the change declares them.
twins :: proc(c: ^change.Change, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for s in c.symbols {
		lines := c.twins[s.name]
		if len(lines) == 0 {
			continue
		}
		fmt.sbprintf(&b, "  %s:%d  %s\n", s.file, s.line, s.signature)
		for line in lines {
			fmt.sbprintf(&b, "      %s\n", strings.trim_suffix(line, "   <- same value"))
		}
	}
	return strings.to_string(b)
}

tests_subject :: proc(c: ^change.Change, allocator: runtime.Allocator) -> string {
	if len(c.tests) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Test functions this change adds or alters:\n\n")
	for t in c.tests {
		fmt.sbprintf(&b, "--- %s:%d %s", t.file, t.line, t.name)
		if t.skips > 0 {
			// The skip is pointed at rather than left to be found, so the
			// reading spends itself on whether the skip is ordinary.
			fmt.sbprintf(&b, "  (skips itself at line %d)", t.skips)
		}
		fmt.sbprintf(&b, "\n%s\n\n", t.body)
	}
	if called := functions_under_test(c, context.temp_allocator); called != "" {
		strings.write_string(
			&b,
			"Functions the tests call, as they stand at the end of the change. A test that\n",
		)
		strings.write_string(
			&b,
			"would pass with one of these returning its input or a zero value is the finding.\n\n",
		)
		strings.write_string(&b, called)
	}
	return strings.to_string(b)
}

// The bounds on what the tests job is shown of the code under test: how
// many functions, and how long each may be before it is cut.
called_functions :: 8
called_lines     :: 60

// functions_under_test renders the functions the tests call, found by
// name in the repository's index, so that whether a test would pass on a
// stub is judged against the function rather than guessed from the test.
// A helper a test file declares is not the code under test.
functions_under_test :: proc(c: ^change.Change, allocator := context.allocator) -> string {
	if len(c.index) == 0 {
		return ""
	}
	declared := make(map[string]change.Declared, context.temp_allocator)
	for d in c.index {
		if d.kind == "func" && d.body != "" && !check.is_test_file(d.file) {
			if d.name not_in declared {
				declared[d.name] = d
			}
		}
	}
	seen := make(map[string]bool, context.temp_allocator)
	shown := make([dynamic]change.Declared, context.temp_allocator)
	outer: for t in c.tests {
		for name in calls(t.body, context.temp_allocator) {
			d, ok := declared[name]
			if !ok || seen[name] || name == t.name {
				continue
			}
			seen[name] = true
			append(&shown, d)
			if len(shown) == called_functions {
				break outer
			}
		}
	}
	if len(shown) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	for d in shown {
		body := d.body
		lines := strings.split_lines(body, context.temp_allocator)
		if len(lines) > called_lines {
			body = fmt.tprintf(
				"%s\n\t… cut at %d lines",
				strings.join(lines[:called_lines], "\n", context.temp_allocator),
				called_lines,
			)
		}
		fmt.sbprintf(&b, "--- %s:%d %s\n%s\n\n", d.file, d.line, d.name, body)
	}
	return strings.to_string(b)
}

// calls are the names a body calls, in order, which is how a test names
// what it tests.
calls :: proc(body: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	it, err := regex.create_iterator(
		body,
		`\b([A-Za-z_][A-Za-z0-9_]*)\(`,
		{},
		context.temp_allocator,
	)
	if err != nil {
		return out[:]
	}
	defer regex.destroy_iterator(it, context.temp_allocator)
	for {
		cap, _, ok := regex.match_iterator(&it)
		if !ok {
			break
		}
		append(&out, strings.trim_suffix(cap.groups[0], "("))
	}
	return out[:]
}

claims_subject :: proc(c: ^change.Change, allocator: runtime.Allocator) -> string {
	blocks := comment_blocks(c.comments[:], context.temp_allocator)
	if len(blocks) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		"Comment and documentation lines this change adds, each with the code beneath it:\n\n",
	)
	for block in blocks {
		for comment in block {
			fmt.sbprintf(&b, "%s:%d  %s\n", comment.file, comment.line, comment.text)
		}
		if below := block[len(block) - 1].below; below != "" {
			rest := below
			for line in strings.split_lines_iterator(&rest) {
				fmt.sbprintf(&b, "    code: %s\n", line)
			}
		}
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

// comment_blocks groups the comments into the runs of consecutive lines
// they were written as, so a claim read over three lines is read whole
// and the code below it is shown once. A comment whose words are the
// code's own is left out: it is never a claim, and measured elsewhere.
comment_blocks :: proc(
	comments: []change.Located,
	allocator := context.allocator,
) -> [][]change.Located {
	blocks := make([dynamic][]change.Located, allocator)
	current := make([dynamic]change.Located, allocator)
	for comment in comments {
		if check.restates(comment) {
			continue
		}
		if len(current) > 0 {
			last := current[len(current) - 1]
			if !(last.file == comment.file && last.line + 1 == comment.line) {
				append(&blocks, current[:])
				current = make([dynamic]change.Located, allocator)
			}
		}
		append(&current, comment)
	}
	if len(current) > 0 {
		append(&blocks, current[:])
	}
	return blocks[:]
}

hygiene_subject :: proc(c: ^change.Change, allocator: runtime.Allocator) -> string {
	if strings.trim_space(c.message) == "" {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Commit message:\n\n")
	strings.write_string(&b, c.message)
	strings.write_string(&b, "\n\nFiles changed:\n")
	strings.write_string(&b, c.stat)
	if len(c.convention) > 0 {
		strings.write_string(
			&b,
			"\nRecent subjects in this repository, as the local convention:\n",
		)
		for subject in c.convention {
			fmt.sbprintf(&b, "  %s\n", subject)
		}
	}
	return strings.to_string(b)
}

// Reported is the shape a job answers in.
Reported :: struct {
	findings: []struct {
		rule:     string `json:"rule"`,
		severity: string `json:"severity"`,
		file:     string `json:"file"`,
		line:     int `json:"line"`,
		symbol:   string `json:"symbol"`,
		message:  string `json:"message"`,
		fix:      string `json:"fix"`,
	} `json:"findings"`,
}

// decode reads a job's answer. A finding that cites no rule from the
// criteria is dropped: the criteria are what gets tuned, so a job may not
// invent one.
decode :: proc(
	raw: string,
	name: string,
	allowed: map[string]bool,
	allocator := context.allocator,
) -> (
	out: []finding.Finding,
	ok: bool,
) {
	r: Reported
	if json.unmarshal_string(raw, &r, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	kept := make([dynamic]finding.Finding, allocator)
	for f in r.findings {
		if !allowed[f.rule] {
			continue
		}
		append(
			&kept,
			finding.Finding {
				job = strings.clone(name, allocator),
				rule = strings.clone(f.rule, allocator),
				severity = finding.parse_severity(f.severity),
				severity_name = strings.clone(f.severity, allocator),
				file = strings.clone(f.file, allocator),
				line = f.line,
				symbol = strings.clone(f.symbol, allocator),
				message = strings.clone(f.message, allocator),
				fix = strings.clone(f.fix, allocator),
			},
		)
	}
	return kept[:], true
}

// readable is whether an answer holds a findings object at all.
readable :: proc(text: string) -> bool {
	raw, found := txt.object(text)
	if !found {
		return false
	}
	r: Reported
	return json.unmarshal_string(raw, &r, allocator = context.temp_allocator) == nil
}

// packet_cap is the size of subject past which a splittable job is asked
// in parts. Under the cap each part is an ask a slow gateway finishes,
// and a part whose files did not change replays from the cache.
packet_cap :: 16000

// parts is the subjects a job is asked, as changes: the whole change when
// it fits or cannot be split, else the change cut file by file into runs
// that each render under the cap. A file that alone renders over the cap
// is a part by itself.
parts :: proc(j: Job, c: ^change.Change, allocator := context.allocator) -> []^change.Change {
	out := make([dynamic]^change.Change, allocator)
	if !j.splittable || len(j.subject(c, context.temp_allocator)) <= packet_cap {
		append(&out, c)
		return out[:]
	}
	group := make([dynamic]string, context.temp_allocator)
	for file in c.files {
		if !contributes(c, file) {
			continue
		}
		if len(group) > 0 {
			trial := slice.clone(group[:], context.temp_allocator)
			with := make([dynamic]string, context.temp_allocator)
			append(&with, ..trial)
			append(&with, file)
			piece := part(c, with[:], context.temp_allocator)
			if len(j.subject(piece, context.temp_allocator)) > packet_cap {
				append(&out, part(c, group[:], allocator))
				clear(&group)
			}
		}
		append(&group, file)
	}
	if len(group) > 0 {
		append(&out, part(c, group[:], allocator))
	}
	return out[:]
}

// contributes is whether a file has anything a splittable job reads.
contributes :: proc(c: ^change.Change, file: string) -> bool {
	for s in c.symbols {
		if s.file == file {
			return true
		}
	}
	for t in c.tests {
		if t.file == file {
			return true
		}
	}
	for comment in c.comments {
		if comment.file == file {
			return true
		}
	}
	return false
}

// part is the change narrowed to some of its files: the declarations,
// tests and comments in them, with everything the jobs read beside those
// — candidates, twins, the index, the message — shared.
part :: proc(
	c: ^change.Change,
	files: []string,
	allocator := context.allocator,
) -> ^change.Change {
	keep := make(map[string]bool, context.temp_allocator)
	for f in files {
		keep[f] = true
	}
	p := new(change.Change, allocator)
	p^ = c^
	p.files = slice.clone(files, allocator)
	p.symbols = make([dynamic]change.Symbol, allocator)
	p.tests = make([dynamic]change.Function, allocator)
	p.comments = make([dynamic]change.Located, allocator)
	for s in c.symbols {
		if keep[s.file] {
			append(&p.symbols, s)
		}
	}
	for t in c.tests {
		if keep[t.file] {
			append(&p.tests, t)
		}
	}
	for comment in c.comments {
		if keep[comment.file] {
			append(&p.comments, comment)
		}
	}
	return p
}
