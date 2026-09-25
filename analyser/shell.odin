package analyser

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "../finding"

// shellcheck lints the changed shell scripts and reads its JSON. It is
// the only analyser here that reads a language by dialect rather than by
// extension: most shell scripts are named for the command they are, and
// the shebang is what says a file is one.
//
// The flags are chosen to leave the repository in charge. Nothing here
// names a dialect or a rule set, so whatever shellcheck settles on and
// whatever .shellcheckrc asks for is what stands, the same courtesy tsc
// and ruff are given with their projects' own settings. -x is asked for
// because a script split across a library is meant to be read as one.
shellcheck := Analyser {
	name = "shellcheck",
	covers = proc(path, shell: string) -> bool {return shell != ""},
	binary = "shellcheck",
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "-f", "json1", "-x")
		append(&args, ..files)
		out, err := execute(tree_dir, "shellcheck", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_shellcheck(tree_dir, out)
	},
}

// Shellcheck_Report is shellcheck's json1 format: one comment per
// finding, with the code as a number rather than its SC spelling.
Shellcheck_Report :: struct {
	comments: []struct {
		file:    string `json:"file"`,
		line:    int `json:"line"`,
		level:   string `json:"level"`,
		code:    int `json:"code"`,
		message: string `json:"message"`,
	} `json:"comments"`,
}

// parse_shellcheck reads shellcheck's json1. An error is a fault: the
// level is reserved for what is wrong rather than what is risky — a
// script that does not parse above all — and a script that does not parse
// does not run, which is the same test every compiler here is held to. A
// warning or an informational note is worth considering; style is a note.
parse_shellcheck :: proc(
	tree_dir, out: string,
	allocator := context.allocator,
) -> (
	[]Diagnostic,
	string,
) {
	report: Shellcheck_Report
	if json.unmarshal_string(out, &report, allocator = context.temp_allocator) != nil {
		return nil, "shellcheck: its answer is not JSON"
	}
	found := make([dynamic]Diagnostic, allocator)
	for c in report.comments {
		severity := finding.Severity.Note
		fault := false
		switch c.level {
		case "error":
			severity, fault = .Must_Fix, true
		case "warning", "info":
			severity = .Consider
		}
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, c.file), allocator),
				line = c.line,
				code = fmt.aprintf("SC%d", c.code, allocator = allocator),
				message = strings.clone(c.message, allocator),
				severity = severity,
				fault = fault,
			},
		)
	}
	return found[:], ""
}
