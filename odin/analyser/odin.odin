package analyser

import "core:encoding/json"
import "core:os"
import "core:strings"

import "../txt"

// odin_check type-checks each package the change touched with every vet
// switch and the compiler's own style, and reads its JSON errors. The
// compiler writes its JSON to stderr and exits non-zero when it has
// errors, which is the answer, not a failure.
odin_check := Analyser {
	name = "odin-check",
	covers = proc(path: string) -> bool {return strings.has_suffix(path, ".odin")},
	ready = proc(tree_dir: string) -> (bool, string) {return on_path("odin"), ""},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		dirs := make(map[string]bool, context.temp_allocator)
		for f in files {
			dirs[dir_of(f)] = true
		}
		found := make([dynamic]Diagnostic)
		for dir in sorted(dirs) {
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "check", dir, "-vet", "-strict-style", "-json-errors", "-no-entry-point")
			append(&args, ..collections(tree_dir))
			stdout, stderr, err := execute_both(tree_dir, "odin", args[:], context.temp_allocator)
			out := strings.concatenate({stdout, stderr}, context.temp_allocator)
			if err != "" && !strings.contains(out, "error_count") {
				return found[:], strings.concatenate({"odin: ", tail(out, 200)})
			}
			append(&found, ..parse_odin(tree_dir, out, context.temp_allocator))
		}
		return found[:], ""
	},
}

// collections are the -collection flags the repository's ols.json
// declares, which is where an Odin project names the collections its
// imports resolve through; a relative path is relative to the repository.
collections :: proc(tree_dir: string, allocator := context.temp_allocator) -> []string {
	Config :: struct {
		collections: []struct {
			name: string `json:"name"`,
			path: string `json:"path"`,
		} `json:"collections"`,
	}
	data, err := os.read_entire_file_from_path(join(tree_dir, "ols.json"), context.temp_allocator)
	if err != nil {
		return nil
	}
	config: Config
	if json.unmarshal(data, &config, allocator = context.temp_allocator) != nil {
		return nil
	}
	flags := make([dynamic]string, allocator)
	for c in config.collections {
		if c.name == "" || c.path == "" {
			continue
		}
		path := c.path
		if !strings.has_prefix(path, "/") {
			path = join(tree_dir, path, allocator)
		}
		append(&flags, strings.concatenate({"-collection:", c.name, "=", path}, allocator))
	}
	return flags[:]
}

// Odin_Report is the compiler's -json-errors.
Odin_Report :: struct {
	errors: []struct {
		type: string `json:"type"`,
		pos:  struct {
			file: string `json:"file"`,
			line: int `json:"line"`,
		} `json:"pos"`,
		msgs: []string `json:"msgs"`,
	} `json:"errors"`,
}

// parse_odin reads the compiler's -json-errors: a type error is a fault,
// a vet failure the vet's opinion, a style failure a note. The compiler
// prints its own prose before the JSON when it cannot even start; the
// object is taken from wherever it sits.
parse_odin :: proc(tree_dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	raw, ok := txt.object(out)
	if !ok {
		return found[:]
	}
	report: Odin_Report
	if json.unmarshal_string(raw, &report, allocator = context.temp_allocator) != nil {
		return found[:]
	}
	for e in report.errors {
		message := strings.join(e.msgs, "; ", allocator)
		d := Diagnostic {
			file     = strings.clone(relative(tree_dir, e.pos.file), allocator),
			line     = e.pos.line,
			message  = message,
			severity = .Must_Fix,
			fault    = true,
		}
		switch {
		case strings.contains(message, "-strict-style"):
			d.code, d.severity, d.fault = "style", .Note, false
		case e.type == "warning":
			d.severity, d.fault = .Consider, false
		case strings.contains(message, "declared but not used"),
		     strings.contains(message, "shadow"):
			// A vet failure fails the build under -vet, but it is the
			// vet's opinion, not a type error.
			d.code, d.severity, d.fault = "vet", .Consider, false
		}
		append(&found, d)
	}
	return found[:]
}
