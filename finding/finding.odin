/*
Package finding is one thing a reading noticed: what it concerns, how
seriously to take it, and the stable name a loop refers to it by. It also
reads the dismissal a source file carries beside what it justifies.
*/
package finding

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// Severity is what a finding means for the change, most serious first.
// Only Must_Fix is worth blocking on; the rest are reported and left to
// judgement, because a loop that treats taste as an error never finishes.
Severity :: enum {
	Must_Fix,
	Consider,
	Note,
}

severity_name :: proc(s: Severity) -> string {
	switch s {
	case .Must_Fix:
		return "must-fix"
	case .Consider:
		return "consider"
	case .Note:
		return "note"
	}
	return "unknown"
}

// parse_severity reads a severity the way a job reports it, defaulting to
// the least serious rather than failing: a job that invents a word should
// not stop the run.
parse_severity :: proc(s: string) -> Severity {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "must-fix", "must fix", "mustfix", "error":
		return .Must_Fix
	case "consider", "warning":
		return .Consider
	}
	return .Note
}

// Finding is one thing a job noticed. The JSON names are the contract's,
// shared with the Go tool, so a loop reads either report the same way.
Finding :: struct {
	// job is the job that reported it; rule the criterion it was judged
	// against. A finding that cites no rule is dropped, so that the
	// criteria are what gets tuned rather than the prompt.
	job:           string `json:"job"`,
	rule:          string `json:"rule"`,
	severity:      Severity `json:"-"`,
	// severity_name is how the severity travels in and out of JSON.
	severity_name: string `json:"severity"`,
	// file and line locate it, where it has a location; symbol names what
	// it concerns, for the findings that are about a name rather than a
	// place.
	file:          string `json:"file,omitempty"`,
	line:          int `json:"line,omitempty"`,
	symbol:        string `json:"symbol,omitempty"`,
	message:       string `json:"message"`,
	// fix is the concrete change suggested, which is what lets an agent
	// act on the finding rather than reason about it again; snippet is the
	// line the finding points at, as it stands.
	fix:           string `json:"fix,omitempty"`,
	snippet:       string `json:"snippet,omitempty"`,
	// verified is what stands behind the finding: the deterministic checks
	// verify themselves; a model's finding is verified when a second
	// reading of the same evidence let it stand.
	verified:      bool `json:"verified"`,
	// id is a stable short name: a hash of what the finding is about, not
	// where it sits, so that a re-run names the same finding again.
	id:            string `json:"id,omitempty"`,
	// part is which part of a split subject the finding came from.
	part:          int `json:"-"`,
}

// to_string is the finding as a person reads it.
to_string :: proc(f: Finding, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, severity_name(f.severity))
	strings.write_string(&b, ": ")
	if f.file != "" {
		strings.write_string(&b, f.file)
		if f.line > 0 {
			fmt.sbprintf(&b, ":%d", f.line)
		}
		strings.write_string(&b, ": ")
	} else if f.symbol != "" {
		strings.write_string(&b, f.symbol)
		strings.write_string(&b, ": ")
	}
	strings.write_string(&b, f.message)
	if f.fix != "" {
		strings.write_string(&b, "\n      → ")
		strings.write_string(&b, f.fix)
	}
	strings.write_string(&b, "\n      [")
	strings.write_string(&b, f.job)
	strings.write_string(&b, "/")
	strings.write_string(&b, f.rule)
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

// sort orders findings so the ones worth reading first are first.
sort :: proc(findings: []Finding) {
	slice.stable_sort_by_cmp(findings, proc(a, b: Finding) -> slice.Ordering {
		if a.severity != b.severity {
			return .Less if a.severity < b.severity else .Greater
		}
		if a.file != b.file {
			return .Less if a.file < b.file else .Greater
		}
		if a.line != b.line {
			return .Less if a.line < b.line else .Greater
		}
		return .Equal
	})
}

// must_fix reports whether any finding is one worth blocking on.
must_fix :: proc(findings: []Finding) -> bool {
	for f in findings {
		if f.severity == .Must_Fix {
			return true
		}
	}
	return false
}

// identify gives a finding its short id: a hash of what it is about, not
// where it sits or how it was worded. The line is left out because lines
// move under edits that do not touch the finding; a model's message is
// left out because a fresh reading may word it differently. A finding
// with no symbol is told from its neighbours by its line, and a
// deterministic check's message is part of what it is about and stable,
// so it stays in. The hash is the Go tool's, byte for byte, so both
// readings name a finding the same.
identify :: proc(f: ^Finding, allocator := context.allocator) {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, f.job, f.rule, f.file, f.symbol)
	switch {
	case f.job == "static":
		append(&parts, f.message)
	case f.symbol == "":
		append(&parts, fmt.tprintf("%d", f.line))
	}
	joined := strings.join(parts[:], "\x00", context.temp_allocator)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)joined)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	encoded := hex.encode(digest[:], context.temp_allocator)
	f.id = strings.clone(string(encoded[:12]), allocator)
}

// name fills in what a finding carries only in the report: its severity
// as text, and the id that names it across runs. Two findings that hash
// the same — one rule, one file, two comments — are told apart by a
// counter, in the order they are listed.
name :: proc(findings: []Finding, allocator := context.allocator) {
	seen := make(map[string]int, context.temp_allocator)
	for &f in findings {
		f.severity_name = severity_name(f.severity)
		identify(&f, allocator)
		seen[f.id] += 1
		if n := seen[f.id]; n > 1 {
			f.id = fmt.aprintf("%s-%d", f.id, n, allocator = allocator)
		}
	}
}

// suppressed reports whether the source dismisses a finding, and with what
// reason. The dismissal lives in the source beside what it justifies:
//
//	//review:ignore <rule> <why>
//
// One on or just above the line it concerns covers that line; one anywhere
// in a file covers the findings that name no line.
suppressed :: proc(
	f: Finding,
	root: string,
	allocator := context.allocator,
) -> (
	why: string,
	ok: bool,
) {
	if f.file == "" {
		return "", false
	}
	path := f.file
	if root != "" {
		path = filepath.join({root, f.file}, context.temp_allocator) or_else f.file
	}
	source, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	text_left := string(source)
	line := 0
	for text in strings.split_lines_iterator(&text_left) {
		line += 1
		rule, reason, found := dismissal(text)
		if !found || !rules_match(rule, f.rule) {
			continue
		}
		if reason == "" {
			reason = "no reason given"
		}
		// A dismissal with no line to answer to covers the file; otherwise
		// it has to sit within a few lines of what it dismisses, so that
		// moving code does not carry a dismissal somewhere it was never
		// meant.
		if f.line == 0 || (line >= f.line - 3 && line <= f.line + 1) {
			return strings.clone(reason, allocator), true
		}
	}
	return "", false
}

// dismissal reads the rule and reason out of a line holding a dismissal:
// two slashes, review:ignore, the rule, and what follows.
dismissal :: proc(text: string) -> (rule, why: string, found: bool) {
	marker :: "review:ignore"
	at := strings.index(text, marker)
	if at < 0 {
		return
	}
	before := strings.trim_right_space(text[:at])
	if !strings.has_suffix(before, "//") {
		return
	}
	rest := strings.trim_left_space(text[at + len(marker):])
	if len(rest) == len(text[at + len(marker):]) {
		return // The marker is not followed by whitespace.
	}
	end := strings.index_any(rest, " \t")
	if end < 0 {
		return rest, "", len(rest) > 0
	}
	return rest[:end], strings.trim_space(rest[end:]), true
}

// rules_match compares a dismissal against a rule, where "all" dismisses
// anything the job found at that spot.
rules_match :: proc(dismissed, rule: string) -> bool {
	return dismissed == "all" || strings.equal_fold(dismissed, rule)
}

// atoi reads a line number a job reported, which may arrive as a string.
atoi :: proc(s: string) -> int {
	n, ok := strconv.parse_int(strings.trim_space(s))
	return n if ok else 0
}
