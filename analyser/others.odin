package analyser

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "jm:sh"

import "../finding"

// is_typescript_or_javascript is whether a path is one of the two.
is_typescript_or_javascript :: proc(path, shell: string) -> bool {
	for ext in ([]string{".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}) {
		if strings.has_suffix(path, ext) {
			return true
		}
	}
	return false
}

// tsc type-checks each project a changed TypeScript file belongs to,
// under the project's own tsconfig — strictness is the project's to set —
// and emits nothing. It needs the project's node_modules, so it reads the
// working tree only.
tsc := Analyser {
	name = "tsc",
	covers = is_typescript_or_javascript,
	in_place = true,
	ready = proc(tree_dir: string) -> (bool, string) {
		if on_path("tsc") || os.is_file(join(tree_dir, "node_modules/.bin/tsc")) {
			return true, ""
		}
		return false, "tsc is not installed, and the project has no node_modules/.bin/tsc"
	},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		binary := join(tree_dir, "node_modules/.bin/tsc")
		if !os.is_file(binary) {
			binary = "tsc"
		}
		projects := make(map[string]bool, context.temp_allocator)
		for f in files {
			if p := nearest(tree_dir, dir_of(f), "tsconfig.json"); p != "" {
				projects[p] = true
			}
		}
		if len(projects) == 0 {
			return nil, "no tsconfig.json above the changed files"
		}
		found := make([dynamic]Diagnostic)
		for project in sorted(projects) {
			dir := join(tree_dir, dir_of(project))
			out, err := execute(
				dir,
				binary,
				{"--noEmit", "--pretty", "false", "-p", "tsconfig.json"},
				context.temp_allocator,
			)
			if err != "" {
				return found[:], err
			}
			append(&found, ..parse_tsc(tree_dir, dir, out, context.temp_allocator))
		}
		return found[:], ""
	},
}

// parse_tsc reads the compiler's plain output — file(line,col): error
// TSnnnn: message — with paths relative to the project directory it ran
// in.
parse_tsc :: proc(tree_dir, dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	re, err := regex.create(
		`^(.+?)\((\d+),(\d+)\): error (TS\d+): (.*)$`,
		{},
		context.temp_allocator,
		context.temp_allocator,
	)
	if err != nil {
		return found[:]
	}
	for line in lines_of(out) {
		cap, ok := regex.match(re, strings.trim_space(line), context.temp_allocator)
		if !ok {
			continue
		}
		number, _ := strconv.parse_int(cap.groups[2])
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, join(dir, cap.groups[1])), allocator),
				line = number,
				code = strings.clone(cap.groups[4], allocator),
				message = strings.clone(cap.groups[5], allocator),
				severity = .Must_Fix,
				fault = true,
			},
		)
	}
	return found[:]
}

is_python :: proc(path, shell: string) -> bool {
	return strings.has_suffix(path, ".py")
}

// ruff lints the changed Python files with the project's own
// configuration and reads its JSON. Its style codes are notes; what
// pyflakes would have said is worth considering.
ruff := Analyser {
	name = "ruff",
	covers = is_python,
	binary = "ruff",
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "check", "--output-format", "json", "--exit-zero")
		append(&args, ..files)
		out, err := execute(tree_dir, "ruff", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_ruff(tree_dir, out)
	},
}

// Ruff_Finding is one entry of ruff's JSON array.
Ruff_Finding :: struct {
	code:     string `json:"code"`,
	message:  string `json:"message"`,
	filename: string `json:"filename"`,
	location: struct {
		row: int `json:"row"`,
	} `json:"location"`,
}

// parse_ruff reads ruff's JSON array. Style codes — E, W, import order,
// docstrings — are notes; the rest is worth considering.
parse_ruff :: proc(
	tree_dir, out: string,
	allocator := context.allocator,
) -> (
	[]Diagnostic,
	string,
) {
	report: []Ruff_Finding
	if json.unmarshal_string(out, &report, allocator = context.temp_allocator) != nil {
		return nil, "ruff: its answer is not JSON"
	}
	found := make([dynamic]Diagnostic, allocator)
	for r in report {
		severity := finding.Severity.Consider
		if strings.has_prefix(r.code, "E") ||
		   strings.has_prefix(r.code, "W") ||
		   strings.has_prefix(r.code, "I") ||
		   strings.has_prefix(r.code, "D") {
			severity = .Note
		}
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, r.filename), allocator),
				line = r.location.row,
				code = strings.clone(r.code, allocator),
				message = strings.clone(r.message, allocator),
				severity = severity,
			},
		)
	}
	return found[:], ""
}

// mypy type-checks the changed Python files and reads its JSON, one
// object per line. Imports it cannot find are the environment's business,
// not the change's, and are not reported.
mypy := Analyser {
	name = "mypy",
	covers = is_python,
	in_place = true,
	binary = "mypy",
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "--output", "json", "--no-error-summary", "--ignore-missing-imports")
		append(&args, ..files)
		out, err := execute(tree_dir, "mypy", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_mypy(tree_dir, out), ""
	},
}

// Mypy_Finding is one line of mypy's JSON.
Mypy_Finding :: struct {
	file:     string `json:"file"`,
	line:     int `json:"line"`,
	message:  string `json:"message"`,
	code:     string `json:"code"`,
	severity: string `json:"severity"`,
}

// parse_mypy reads mypy's JSON, one object per line: an error is a type
// error and must-fix, anything else a note.
parse_mypy :: proc(tree_dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	for line in lines_of(out) {
		r: Mypy_Finding
		if json.unmarshal_string(line, &r, allocator = context.temp_allocator) != nil ||
		   r.file == "" {
			continue
		}
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, r.file), allocator),
				line = r.line,
				code = strings.clone(r.code, allocator),
				message = strings.clone(r.message, allocator),
				severity = .Must_Fix if r.severity == "error" else .Note,
			},
		)
	}
	return found[:]
}

// cargo type-checks each crate a changed Rust file belongs to — with
// clippy where it is installed, which checks and lints in one run — and
// reads the compiler's JSON messages. The target directory is the
// repository's own, so a range's materialised tree reuses the build
// cache.
cargo := Analyser {
	name = "cargo",
	covers = proc(path, shell: string) -> bool {return strings.has_suffix(path, ".rs")},
	binary = "cargo",
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		crates := make(map[string]bool, context.temp_allocator)
		for f in files {
			if c := nearest(tree_dir, dir_of(f), "Cargo.toml"); c != "" {
				crates[c] = true
			}
		}
		if len(crates) == 0 {
			return nil, "no Cargo.toml above the changed files"
		}
		verb :=
			"clippy" if sh.exec({"cargo", "clippy", "--version"}, allocator = context.temp_allocator).ok else "check"
		found := make([dynamic]Diagnostic)
		for crate in sorted(crates) {
			dir := join(tree_dir, dir_of(crate))
			target := join(root, join(dir_of(crate), "target"))
			os.set_env("CARGO_TARGET_DIR", target)
			out, err := execute(
				dir,
				"cargo",
				{verb, "--message-format", "json", "--quiet"},
				context.temp_allocator,
			)
			os.unset_env("CARGO_TARGET_DIR")
			if err != "" {
				return found[:], err
			}
			append(&found, ..parse_cargo(tree_dir, dir, out, context.temp_allocator))
		}
		return found[:], ""
	},
}

// Cargo_Event is one line of cargo's JSON stream.
Cargo_Event :: struct {
	reason:  string `json:"reason"`,
	message: struct {
		level:   string `json:"level"`,
		message: string `json:"message"`,
		code:    Maybe(struct {
				code: string `json:"code"`,
			}) `json:"code"`,
		spans:   []struct {
			file:    string `json:"file_name"`,
			line:    int `json:"line_start"`,
			primary: bool `json:"is_primary"`,
		} `json:"spans"`,
	} `json:"message"`,
}

// parse_cargo reads the compiler messages out of cargo's JSON stream, one
// per primary span, with paths relative to the crate directory it ran in.
parse_cargo :: proc(tree_dir, dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	for line in lines_of(out) {
		event: Cargo_Event
		if json.unmarshal_string(line, &event, allocator = context.temp_allocator) != nil ||
		   event.reason != "compiler-message" {
			continue
		}
		for span in event.message.spans {
			if !span.primary {
				continue
			}
			d := Diagnostic {
				file    = strings.clone(relative(tree_dir, join(dir, span.file)), allocator),
				line    = span.line,
				message = strings.clone(event.message.message, allocator),
			}
			if code, given := event.message.code.?; given {
				d.code = strings.clone(code.code, allocator)
			}
			switch event.message.level {
			case "error":
				d.severity, d.fault = .Must_Fix, true
			case "warning":
				d.severity = .Consider
			case:
				continue
			}
			append(&found, d)
			break
		}
	}
	return found[:]
}

// semgrep_languages are the extensions semgrep parses: its rules are
// about patterns, not types, and say things a compiler does not.
semgrep_languages :: `.go .ts .tsx .js .jsx .mjs .cjs .py .rs .java .kt .kts .rb .php .c .h .cc .cpp .hpp .cs
	.swift .scala .lua .ex .exs .dart .sh .bash .ksh .bats .tf .yaml .yml .json .html .sol`

// semgrep_config is the rule set semgrep is pointed at: the repository's
// own configuration where it has one — that is the repository's word on
// what matters — and the registry's default pack otherwise, fetched over
// the network. Not auto: semgrep refuses to build that selection with
// metrics off, and review never sends metrics.
semgrep_config :: proc(tree_dir: string) -> string {
	for name in ([]string{".semgrep.yml", ".semgrep.yaml", ".semgrep"}) {
		if os.exists(join(tree_dir, name)) {
			return name
		}
	}
	return "p/default"
}

// semgrep runs the pattern analyser over the changed files it can parse,
// and reads its JSON. A rule's severity is the rule author's word on it,
// kept as reported: ERROR must-fix, WARNING consider, INFO note.
semgrep := Analyser {
	name = "semgrep",
	covers = proc(path, shell: string) -> bool {
		// A workflow is read by actionlint and zizmor, which were built
		// for it; semgrep's rules for one repeat what they say, and a
		// reader who is told a thing twice trusts the report less.
		if is_workflow(path, shell) {
			return false
		}
		for ext in strings.fields(semgrep_languages, context.temp_allocator) {
			if strings.has_suffix(path, ext) {
				return true
			}
		}
		return false
	},
	binary = "semgrep",
	ready = proc(tree_dir: string) -> (bool, string) {return true, ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		args := make([dynamic]string, context.temp_allocator)
		append(
			&args,
			"scan",
			"--json",
			"--quiet",
			"--config",
			semgrep_config(tree_dir),
			"--metrics",
			"off",
		)
		append(&args, ..files)
		out, err := execute(tree_dir, "semgrep", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_semgrep(tree_dir, out)
	},
}

// Semgrep_Report is semgrep's JSON report: one result per match.
Semgrep_Report :: struct {
	results: []struct {
		check_id: string `json:"check_id"`,
		path:     string `json:"path"`,
		start:    struct {
			line: int `json:"line"`,
		} `json:"start"`,
		extra:    struct {
			message:  string `json:"message"`,
			severity: string `json:"severity"`,
		} `json:"extra"`,
	} `json:"results"`,
}

// parse_semgrep reads semgrep's JSON report, located by each match's
// start line, with the rule's id and severity.
parse_semgrep :: proc(
	tree_dir, out: string,
	allocator := context.allocator,
) -> (
	[]Diagnostic,
	string,
) {
	report: Semgrep_Report
	if json.unmarshal_string(out, &report, allocator = context.temp_allocator) != nil {
		return nil, "semgrep: its answer is not JSON"
	}
	found := make([dynamic]Diagnostic, allocator)
	for r in report.results {
		severity := finding.Severity.Note
		switch strings.to_upper(r.extra.severity, context.temp_allocator) {
		case "ERROR", "HIGH", "CRITICAL":
			severity = .Must_Fix
		case "WARNING", "MEDIUM":
			severity = .Consider
		}
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, r.path), allocator),
				line = r.start.line,
				code = strings.clone(r.check_id, allocator),
				message = strings.clone(strings.trim_space(r.extra.message), allocator),
				severity = severity,
			},
		)
	}
	return found[:], ""
}
