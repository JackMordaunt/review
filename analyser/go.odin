package analyser

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "jm:sh"

import "../finding"

is_go :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".go")
}

// go_ready is whether a Go tool can run: the binary, and a module at the
// tree's root.
go_ready :: proc(binary: string, tree_dir: string) -> (bool, string) {
	if !on_path(binary) {
		return false, ""
	}
	if !os.is_file(join(tree_dir, "go.mod")) {
		return false, "no go.mod at the repository root"
	}
	return true, ""
}

// go_packages names the packages of the files, as patterns the go command
// takes. The leading ./ is load-bearing: without it a directory reads as a
// module path and matches nothing.
go_packages :: proc(tree_dir: string, files: []string) -> []string {
	dirs := make(map[string]bool, context.temp_allocator)
	for f in files {
		dir := dir_of(f)
		if dir == "vendor" || strings.has_prefix(dir, "vendor/") {
			continue
		}
		if !os.is_dir(join(tree_dir, dir)) {
			continue
		}
		// A directory under a go.mod of its own is another module's, and
		// the go command run at the root cannot name it.
		if nested_module(tree_dir, dir) {
			continue
		}
		dirs[dir] = true
	}
	out := make([dynamic]string, context.temp_allocator)
	for dir in dirs {
		append(&out, strings.concatenate({"./", dir}, context.temp_allocator))
	}
	slice.sort(out[:])
	return out[:]
}

// nested_module is whether a directory sits under a go.mod below the
// tree's root, which makes it another module's package.
nested_module :: proc(tree_dir, dir: string) -> bool {
	d := dir
	for d != "." && d != "" && d != "/" {
		if os.is_file(join(tree_dir, join(d, "go.mod"))) {
			return true
		}
		d = dir_of(d)
	}
	return false
}

// go_build compiles the packages the change touched. What does not
// compile is the change's wherever the error lands.
go_build := Analyser {
	name = "go-build",
	covers = is_go,
	ready = proc(tree_dir: string) -> (bool, string) {return go_ready("go", tree_dir)},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		pkgs := go_packages(tree_dir, files)
		if len(pkgs) == 0 {
			return nil, ""
		}
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "build", "-json", "-o", "/dev/null")
		append(&args, ..pkgs)
		out, err := execute(tree_dir, "go", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_go_build(tree_dir, out), ""
	},
}

// parse_go_build reads the compiler's errors out of go build -json: build
// events whose output lines are file:line:col: message, relative to the
// tree.
parse_go_build :: proc(tree_dir, out: string, allocator := context.allocator) -> []Diagnostic {
	Event :: struct {
		action: string `json:"Action"`,
		output: string `json:"Output"`,
	}
	found := make([dynamic]Diagnostic, allocator)
	for line in lines_of(out) {
		event: Event
		if json.unmarshal_string(line, &event, allocator = context.temp_allocator) != nil ||
		   event.action != "build-output" {
			continue
		}
		for text in lines_of(event.output) {
			if strings.has_prefix(text, "#") {
				continue
			}
			file, number, message, ok := position(strings.trim_space(text))
			if !ok {
				continue
			}
			append(
				&found,
				Diagnostic {
					file = strings.clone(relative(tree_dir, file), allocator),
					line = number,
					message = strings.clone(message, allocator),
					severity = .Must_Fix,
					fault = true,
				},
			)
		}
	}
	return found[:]
}

// vet_tool is the multichecker built from sidecar/govet: vet's own
// analysers and the ones from golang.org/x/tools it leaves out. When it
// is on the path, vet runs it instead of its default set.
vet_tool :: "review-vet"

// modernizers are the names of the modernize suite's analysers, which
// report an older idiom where a newer one exists.
modernizers :: `any atomictypes embedlit errorsastype forvar importcomment mapsloop minmax newexpr
	omitzero plusbuild rangeint reflecttypeassert reflecttypefor slicesbackward slicesclip slicescontains slicessort
	stditerators stringscut stringscutprefix stringsseq stringsbuilder testingcontext unsafefuncs waitgroup`

// vet_severity is how seriously to take one of vet's analysers. Vet's
// default set and the bug-finding extras are faults the analyser argues
// for; shadow and unusedwrite are judgement; modernize is taste.
vet_severity :: proc(analyzer: string) -> finding.Severity {
	switch analyzer {
	case "shadow", "unusedwrite":
		return .Consider
	}
	if strings.has_prefix(analyzer, "modernize") {
		return .Note
	}
	for name in strings.fields(modernizers, context.temp_allocator) {
		if name == analyzer {
			return .Note
		}
	}
	return .Must_Fix
}

// go_vet runs vet over the packages the change touched — with review-vet
// where it is installed — and reads its JSON.
go_vet := Analyser {
	name = "go-vet",
	covers = is_go,
	ready = proc(tree_dir: string) -> (bool, string) {return go_ready("go", tree_dir)},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		pkgs := go_packages(tree_dir, files)
		if len(pkgs) == 0 {
			return nil, ""
		}
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "vet", "-json")
		if tool, found := sh.which(vet_tool, context.temp_allocator); found {
			append(&args, strings.concatenate({"-vettool=", tool}, context.temp_allocator))
		}
		append(&args, ..pkgs)
		out, err := execute(tree_dir, "go", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_go_vet(tree_dir, out), ""
	},
}

// Vet_Finding is one thing one of vet's analysers said.
Vet_Finding :: struct {
	posn:    string `json:"posn"`,
	message: string `json:"message"`,
}

// parse_go_vet reads vet's JSON: one object per package, one list per
// analyser. The JSON is preceded by a comment line naming the package, and
// a package that fails to type-check is reported in prose rather than
// JSON; both are skipped, since the build has already said what does not
// compile.
parse_go_vet :: proc(tree_dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	for chunk in split_json_objects(out, context.temp_allocator) {
		report: map[string]map[string][]Vet_Finding
		if json.unmarshal_string(chunk, &report, allocator = context.temp_allocator) != nil {
			continue
		}
		for _, analysers in report {
			for analyzer in sorted(analysers) {
				for f in analysers[analyzer] {
					file, line := split_position(f.posn)
					if file == "" {
						continue
					}
					append(
						&found,
						Diagnostic {
							file = strings.clone(relative(tree_dir, file), allocator),
							line = line,
							code = strings.clone(analyzer, allocator),
							message = strings.clone(f.message, allocator),
							severity = vet_severity(analyzer),
						},
					)
				}
			}
		}
	}
	return found[:]
}

// sorted is a map's keys in order.
sorted :: proc(m: map[string]$V) -> []string {
	keys, _ := slice.map_keys(m, context.temp_allocator)
	slice.sort(keys)
	return keys
}

// split_position reads file and line out of file:line:col.
split_position :: proc(posn: string) -> (file: string, line: int) {
	rest := posn
	// The column, then the line, are the last two colon-separated fields.
	last := strings.last_index_byte(rest, ':')
	if last < 0 {
		return "", 0
	}
	if _, is_number := parse_number(rest[last + 1:]); is_number {
		prev := strings.last_index_byte(rest[:last], ':')
		if prev >= 0 {
			if n, ok := parse_number(rest[prev + 1:last]); ok {
				return rest[:prev], n
			}
		}
		n, _ := parse_number(rest[last + 1:])
		return rest[:last], n
	}
	return "", 0
}

parse_number :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(s[i] - '0')
	}
	return n, true
}

// staticcheck is the Go analyser beyond vet, run with JSON output over
// the packages the change touched. Only a finding code — SA4006, S1002 —
// is a finding about the code; a compile error the build has already
// reported.
staticcheck := Analyser {
	name = "staticcheck",
	covers = is_go,
	ready = proc(tree_dir: string) -> (bool, string) {return go_ready("staticcheck", tree_dir)},
	run = proc(tree_dir, root: string, files: []string) -> ([]Diagnostic, string) {
		pkgs := go_packages(tree_dir, files)
		if len(pkgs) == 0 {
			return nil, ""
		}
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "-f", "json")
		append(&args, ..pkgs)
		out, err := execute(tree_dir, "staticcheck", args[:], context.temp_allocator)
		if err != "" {
			return nil, err
		}
		return parse_staticcheck(tree_dir, out), ""
	},
}

// Problem is one finding in staticcheck's -f json output, one object per
// line.
Problem :: struct {
	code:     string `json:"code"`,
	location: struct {
		file: string `json:"file"`,
		line: int `json:"line"`,
	} `json:"location"`,
	message:  string `json:"message"`,
}

parse_staticcheck :: proc(tree_dir, out: string, allocator := context.allocator) -> []Diagnostic {
	found := make([dynamic]Diagnostic, allocator)
	for line in lines_of(out) {
		p: Problem
		if json.unmarshal_string(line, &p, allocator = context.temp_allocator) != nil ||
		   !is_check_code(p.code) {
			continue
		}
		append(
			&found,
			Diagnostic {
				file = strings.clone(relative(tree_dir, p.location.file), allocator),
				line = p.location.line,
				code = strings.clone(p.code, allocator),
				message = strings.clone(p.message, allocator),
				severity = staticcheck_severity(p.code),
			},
		)
	}
	return found[:]
}

// is_check_code is whether a code is a staticcheck finding code: capitals
// then digits.
is_check_code :: proc(code: string) -> bool {
	i := 0
	for i < len(code) && code[i] >= 'A' && code[i] <= 'Z' {
		i += 1
	}
	if i == 0 || i == len(code) {
		return false
	}
	for j in i ..< len(code) {
		if code[j] < '0' || code[j] > '9' {
			return false
		}
	}
	return true
}

// staticcheck_severity maps a staticcheck category onto the report's
// severities. SA is a fault the analyser argues for; U is code that serves
// nobody, and S a simplification; ST and QF are style.
staticcheck_severity :: proc(code: string) -> finding.Severity {
	switch {
	case strings.has_prefix(code, "SA"):
		return .Must_Fix
	case (strings.has_prefix(code, "S") && !strings.has_prefix(code, "ST")) ||
	     strings.has_prefix(code, "U"):
		return .Consider
	}
	return .Note
}
