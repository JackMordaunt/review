package analyser

// A workflow is code that runs with the repository's credentials, and the
// two tools that read it answer different questions: actionlint whether
// the workflow is right, zizmor whether it is safe.

import "core:encoding/json"
import "core:strings"

import "../finding"

// is_workflow is whether a path is a GitHub Actions workflow. They live
// in one directory by the platform's rule, so the directory is the test
// rather than the extension, which every other YAML file shares.
is_workflow :: proc(path, shell: string) -> bool {
	if !strings.contains(path, ".github/workflows/") {
		return false
	}
	return strings.has_suffix(path, ".yml") || strings.has_suffix(path, ".yaml")
}

// actionlint checks the changed workflows and reads its JSON. It runs
// shellcheck over each run: block as part of the job, which is how the
// shell in a workflow gets the same reading a script does.
actionlint := Analyser {
	name = "actionlint",
	binary = "actionlint",
	covers = is_workflow,
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "-format", "{{json .}}", "-no-color")
		append(&args, ..files)
		out, err := execute(tree_dir, "actionlint", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_actionlint(tree_dir, out)
	},
}

// Actionlint_Finding is one entry of actionlint's JSON array. kind is the
// rule that found it.
Actionlint_Finding :: struct {
	message:  string `json:"message"`,
	filepath: string `json:"filepath"`,
	line:     int `json:"line"`,
	kind:     string `json:"kind"`,
}

// parse_actionlint reads actionlint's JSON array. A workflow that does
// not parse is a fault — the platform will not run it, so it is the
// change's wherever it lands — and everything else is worth considering.
parse_actionlint :: proc(
	tree_dir, out: string,
	allocator := context.allocator,
) -> (
	[]Diagnostic,
	string,
) {
	report: []Actionlint_Finding
	if json.unmarshal_string(out, &report, allocator = context.temp_allocator) != nil {
		return nil, "actionlint: its answer is not JSON"
	}
	found := make([dynamic]Diagnostic, allocator)
	for r in report {
		fault := r.kind == "syntax-check"
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, r.filepath), allocator),
				line = r.line,
				code = strings.clone(r.kind, allocator),
				message = strings.clone(r.message, allocator),
				severity = .Must_Fix if fault else .Consider,
				fault = fault,
			},
		)
	}
	return found[:], ""
}

// zizmor audits the changed workflows for what they let an attacker do —
// a template expansion that runs their text, a credential left on disk, a
// permission wider than the job needs. It is asked for JSON and left in
// its default persona and offline mode, so it reaches no network.
zizmor := Analyser {
	name = "zizmor",
	binary = "zizmor",
	covers = is_workflow,
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "--format", "json", "--no-progress")
		append(&args, ..files)
		out, err := execute(tree_dir, "zizmor", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_zizmor(tree_dir, out)
	},
}

// Zizmor_Finding is one entry of zizmor's JSON array. A finding carries
// several locations — the step it sits in, the line it is about, the
// lines it relates to — and only the primary one is where the reader
// should look. Rows are counted from zero.
Zizmor_Finding :: struct {
	ident:          string `json:"ident"`,
	desc:           string `json:"desc"`,
	determinations: struct {
		severity: string `json:"severity"`,
	} `json:"determinations"`,
	locations:      []struct {
		symbolic: struct {
			kind:       string `json:"kind"`,
			annotation: string `json:"annotation"`,
			key:        struct {
				local: struct {
					path: string `json:"verbatim_path"`,
				} `json:"Local"`,
			} `json:"key"`,
		} `json:"symbolic"`,
		concrete: struct {
			location: struct {
				start: struct {
					row: int `json:"row"`,
				} `json:"start_point"`,
			} `json:"location"`,
		} `json:"concrete"`,
	} `json:"locations"`,
}

// parse_zizmor reads zizmor's JSON array, one diagnostic per finding,
// located at its primary location. The severity is the audit's own word
// on it, kept as reported, and none of them is a fault: a workflow that
// hands an attacker the runner still runs.
parse_zizmor :: proc(
	tree_dir, out: string,
	allocator := context.allocator,
) -> (
	[]Diagnostic,
	string,
) {
	report: []Zizmor_Finding
	if json.unmarshal_string(out, &report, allocator = context.temp_allocator) != nil {
		return nil, "zizmor: its answer is not JSON"
	}
	found := make([dynamic]Diagnostic, allocator)
	for r in report {
		for l in r.locations {
			if l.symbolic.kind != "Primary" {
				continue
			}
			severity := finding.Severity.Note
			switch strings.to_lower(r.determinations.severity, context.temp_allocator) {
			case "high":
				severity = .Must_Fix
			case "medium":
				severity = .Consider
			}
			message := r.desc
			if note := strings.trim_space(l.symbolic.annotation); note != "" {
				message = strings.concatenate({r.desc, ": ", note}, context.temp_allocator)
			}
			append(
				&found,
				Diagnostic {
					file = strings.clone(relative(tree_dir, l.symbolic.key.local.path), allocator),
					// zizmor counts rows from zero; every other reader
					// here counts the lines a person sees.
					line = l.concrete.location.start.row + 1,
					code = strings.clone(r.ident, allocator),
					message = strings.clone(message, allocator),
					severity = severity,
				},
			)
			break
		}
	}
	return found[:], ""
}
