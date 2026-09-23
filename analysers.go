package main

// The compilers and analysers a repository's languages already have are the
// deterministic checks with the most to say, and review has nothing to
// teach them. What it decides is which of their findings belong to the
// change: an error anywhere in a unit the change touched is the change's
// to answer, because the tree does not compile until it is; a warning is
// the change's only where it lands on a line the change added. Each is run
// with its strictest settings and asked for JSON, on the tree the change
// arrives at.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// analyserTimeout bounds one analyser's run. A cold first analysis of a
// large module can take minutes; past this the analyser says nothing rather
// than holding the review, and the run warms the cache for the next one.
const analyserTimeout = 5 * time.Minute

// Diagnostic is one thing an analyser said, located in the tree.
type Diagnostic struct {
	File     string
	Line     int
	Code     string
	Message  string
	Severity Severity
	// Fault is whether the diagnostic is a compile error — the tree does
	// not build — rather than an analyser's opinion about code that does.
	Fault bool
}

// Analyser is one compiler or analyser, run over the units the change's
// files belong to.
type Analyser struct {
	// Name labels the analyser and prefixes its rule ids: name/code.
	Name string
	// Covers is whether a path is one of the analyser's language.
	Covers func(path string) bool
	// Ready is whether the analyser can run in this tree: its binary is on
	// the path, and the tree has what it needs. The reason it cannot is
	// told once, on stderr.
	Ready func(tree string) (bool, string)
	// Run analyses the units the files belong to, in the tree, and returns
	// what it found with paths relative to the tree.
	Run func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error)
	// InPlace is whether the analyser needs the working tree's surroundings
	// — installed packages, a node_modules — and so cannot read a range's
	// materialised tree.
	InPlace bool
}

// Analysers are the compilers and analysers review knows how to run, in the
// order their findings are worth having.
func Analysers() []Analyser {
	return []Analyser{goBuild, goVet, staticcheckAnalyser, odinCheck, tsc, ruff, mypy, cargoCheck, semgrep}
}

// checkAnalysers runs every analyser that covers a changed file and can run,
// and keeps the findings that belong to the change.
func checkAnalysers(root, rev string, c *Change, analysers ...Analyser) []Finding {
	tree, err := treeAt(root, rev)
	if err != nil {
		return nil
	}
	_, ranged := ends(rev)
	added := addedLines(c.Diff)
	changed := map[string]bool{}
	for _, f := range c.Files {
		changed[f] = true
	}
	var out []Finding
	for _, a := range analysers {
		var files []string
		for _, f := range c.Files {
			if a.Covers(f) && tree.Exists(f) {
				files = append(files, f)
			}
		}
		if len(files) == 0 {
			continue
		}
		if ready, why := a.Ready(tree.Dir()); !ready {
			if why != "" {
				fmt.Fprintf(os.Stderr, "skipping %s: %s\n", a.Name, why)
			}
			continue
		}
		if a.InPlace && ranged {
			fmt.Fprintf(os.Stderr, "skipping %s: it reads the working tree, and the change is a range\n", a.Name)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), analyserTimeout)
		diagnostics, err := a.Run(ctx, tree.Dir(), root, files)
		expired := errors.Is(ctx.Err(), context.DeadlineExceeded)
		cancel()
		if expired {
			fmt.Fprintf(os.Stderr, "skipping %s: a run past %v is not waited for\n", a.Name, analyserTimeout)
			continue
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "skipping %s: %s\n", a.Name, first(err.Error(), 200))
			continue
		}
		seen := map[string]bool{}
		for _, d := range diagnostics {
			if d.File == "" || d.Line == 0 {
				continue
			}
			// A fault is the change's wherever it lands: the unit it
			// touched no longer compiles. An opinion is the change's only
			// on a line it added.
			if !d.Fault && (!changed[d.File] || !slices.Contains(added[d.File], d.Line)) {
				continue
			}
			key := fmt.Sprintf("%s:%d:%s:%s", d.File, d.Line, d.Code, d.Message)
			if seen[key] {
				continue
			}
			seen[key] = true
			rule := a.Name
			if d.Code != "" {
				rule += "/" + d.Code
			}
			out = append(out, Finding{
				Job: "static", Rule: rule, Severity: d.Severity,
				File: d.File, Line: d.Line, Message: d.Message,
			})
		}
	}
	return out
}

// execute works one command in the tree and returns its output. A command that
// reports findings by exiting non-zero is not a failed run: its stdout is
// the answer, and only an empty stdout with a non-zero exit is a fault.
func execute(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	stdout, stderr, err := executeBoth(ctx, dir, env, name, args...)
	if err != nil && len(stdout) == 0 {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		return nil, fmt.Errorf("%s: %s", name, tail(orElse(strings.TrimSpace(string(stderr)), err.Error()), 200))
	}
	return stdout, nil
}

// executeBoth works one command and returns both streams: the Odin compiler
// writes its JSON to stderr, and a tool that fails before it starts says
// why there too.
func executeBoth(ctx context.Context, dir string, env []string, name string, args ...string) (stdout, stderr []byte, err error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = append(os.Environ(), env...)
	}
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	err = cmd.Run()
	return out.Bytes(), errs.Bytes(), err
}

// onPath is a Ready that needs only the binary.
func onPath(binary string) func(string) (bool, string) {
	return func(string) (bool, string) {
		if _, err := exec.LookPath(binary); err != nil {
			return false, ""
		}
		return true, ""
	}
}

// goReady is whether a Go tool can run: the go command, and a module at the
// tree's root.
func goReady(binary string) func(string) (bool, string) {
	return func(tree string) (bool, string) {
		if _, err := exec.LookPath(binary); err != nil {
			return false, ""
		}
		if _, err := os.Stat(filepath.Join(tree, "go.mod")); err != nil {
			return false, "no go.mod at the repository root"
		}
		return true, ""
	}
}

func isGo(path string) bool { return strings.HasSuffix(path, ".go") }

// goPackages names the packages of the files, as patterns the go command
// takes. The leading ./ is load-bearing: without it a directory reads as a
// module path and matches nothing.
func goPackages(tree string, files []string) []string {
	dirs := map[string]bool{}
	for _, f := range files {
		dir := filepath.Dir(f)
		if dir == "vendor" || strings.HasPrefix(dir, "vendor/") {
			continue
		}
		if _, err := os.Stat(filepath.Join(tree, dir)); err != nil {
			continue
		}
		dirs[dir] = true
	}
	var out []string
	for dir := range dirs {
		out = append(out, "./"+filepath.ToSlash(dir))
	}
	slices.Sort(out)
	return out
}

// position matches the file:line:column: message the Go tools print.
var position = regexp.MustCompile(`^(.+?):(\d+)(?::(\d+))?: (.*)$`)

// goBuild compiles the packages the change touched. What does not compile
// is the change's wherever the error lands.
var goBuild = Analyser{
	Name:   "go-build",
	Covers: isGo,
	Ready:  goReady("go"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		pkgs := goPackages(tree, files)
		if len(pkgs) == 0 {
			return nil, nil
		}
		out, err := execute(ctx, tree, nil, "go", append([]string{"build", "-json", "-o", os.DevNull}, pkgs...)...)
		if err != nil {
			return nil, err
		}
		return parseGoBuild(tree, out), nil
	},
}

// parseGoBuild reads the compiler's errors out of go build -json: build
// events whose output lines are file:line:col: message, relative to the
// tree.
func parseGoBuild(tree string, out []byte) []Diagnostic {
	var diagnostics []Diagnostic
	for _, line := range bytes.Split(out, []byte("\n")) {
		var event struct {
			Action string `json:"Action"`
			Output string `json:"Output"`
		}
		if json.Unmarshal(line, &event) != nil || event.Action != "build-output" {
			continue
		}
		for _, text := range strings.Split(event.Output, "\n") {
			m := position.FindStringSubmatch(strings.TrimSpace(text))
			if m == nil || strings.HasPrefix(text, "#") {
				continue
			}
			file := relative(tree, filepath.Join(tree, filepath.FromSlash(m[1])))
			diagnostics = append(diagnostics, Diagnostic{
				File: filepath.ToSlash(file), Line: atoi(m[2]), Message: m[4],
				Severity: MustFix, Fault: true,
			})
		}
	}
	return diagnostics
}

// vetTool is the multichecker built from sidecar/govet: vet's own analysers
// and the ones from golang.org/x/tools it leaves out — nilness, shadow,
// unusedwrite and the rest. When it is on the path, vet runs it instead of
// its default set.
const vetTool = "review-vet"

// vetSeverity is how seriously to take one of vet's analysers. Vet's default
// set and the bug-finding extras are faults the analyser argues for; shadow
// and unusedwrite are judgement; modernize is taste.
func vetSeverity(analyzer string) Severity {
	switch analyzer {
	case "shadow", "unusedwrite":
		return Consider
	}
	if strings.HasPrefix(analyzer, "modernize") || slices.Contains(modernizers, analyzer) {
		return Note
	}
	return MustFix
}

// modernizers are the names of the modernize suite's analysers, which report
// an older idiom where a newer one exists.
var modernizers = strings.Fields(`any atomictypes embedlit errorsastype forvar importcomment mapsloop minmax newexpr
	omitzero plusbuild rangeint reflecttypeassert reflecttypefor slicesbackward slicesclip slicescontains slicessort
	stditerators stringscut stringscutprefix stringsseq stringsbuilder testingcontext unsafefuncs waitgroup`)

// goVet runs vet over the packages the change touched — with review-vet
// where it is installed — and reads its JSON: one object per package, one
// list per analyser.
var goVet = Analyser{
	Name:   "go-vet",
	Covers: isGo,
	Ready:  goReady("go"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		pkgs := goPackages(tree, files)
		if len(pkgs) == 0 {
			return nil, nil
		}
		args := []string{"vet", "-json"}
		if tool, err := exec.LookPath(vetTool); err == nil {
			args = append(args, "-vettool="+tool)
		}
		out, err := execute(ctx, tree, nil, "go", append(args, pkgs...)...)
		if err != nil {
			return nil, err
		}
		return parseGoVet(tree, out), nil
	},
}

// parseGoVet reads vet's JSON: one object per package, one list per
// analyser. The JSON is preceded by a comment line naming the package, and
// a package that fails to type-check is reported in prose rather than JSON;
// both are skipped, since the build has already said what does not compile.
func parseGoVet(tree string, out []byte) []Diagnostic {
	var diagnostics []Diagnostic
	{
		for _, chunk := range splitJSONObjects(out) {
			var report map[string]map[string][]struct {
				Posn    string `json:"posn"`
				Message string `json:"message"`
			}
			if json.Unmarshal(chunk, &report) != nil {
				continue
			}
			for _, analysers := range report {
				for analyzer, found := range analysers {
					for _, f := range found {
						file, line := splitPosition(f.Posn)
						if file == "" {
							continue
						}
						if filepath.IsAbs(file) {
							file = relative(tree, file)
						}
						diagnostics = append(diagnostics, Diagnostic{
							File: filepath.ToSlash(file), Line: line, Code: analyzer,
							Message: f.Message, Severity: vetSeverity(analyzer),
						})
					}
				}
			}
		}
	}
	return diagnostics
}

// splitJSONObjects cuts a stream of top-level JSON objects, with anything
// between them — vet's # comment lines, prose about a failed package — left
// out. An object opens only at the start of a line, as vet writes them, so
// a brace in the prose opens nothing.
func splitJSONObjects(out []byte) [][]byte {
	var chunks [][]byte
	depth, start := 0, -1
	inString, lineStart := false, true
	for i := 0; i < len(out); i++ {
		c := out[i]
		switch {
		case inString:
			if c == '\\' {
				i++
			} else if c == '"' {
				inString = false
			}
		case depth > 0 && c == '"':
			inString = true
		case c == '{' && (depth > 0 || lineStart):
			if depth == 0 {
				start = i
			}
			depth++
		case c == '}' && depth > 0:
			depth--
			if depth == 0 {
				chunks = append(chunks, out[start:i+1])
				start = -1
			}
		}
		lineStart = c == '\n'
	}
	return chunks
}

// splitPosition reads file and line out of file:line:col.
func splitPosition(posn string) (string, int) {
	m := regexp.MustCompile(`^(.+?):(\d+)(?::\d+)?$`).FindStringSubmatch(posn)
	if m == nil {
		return "", 0
	}
	return m[1], atoi(m[2])
}

// odinCheck type-checks each package the change touched with every vet
// switch and the compiler's own style, and reads its JSON errors.
var odinCheck = Analyser{
	Name:   "odin-check",
	Covers: func(path string) bool { return strings.HasSuffix(path, ".odin") },
	Ready:  onPath("odin"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		dirs := map[string]bool{}
		for _, f := range files {
			dirs[filepath.Dir(f)] = true
		}
		var diagnostics []Diagnostic
		for _, dir := range slices.Sorted(func(yield func(string) bool) {
			for d := range dirs {
				if !yield(d) {
					return
				}
			}
		}) {
			// The compiler writes its JSON to stderr and exits non-zero
			// when it has errors, which is the answer, not a failure.
			args := append([]string{"check", dir, "-vet", "-strict-style", "-json-errors", "-no-entry-point"}, odinCollections(tree)...)
			stdout, stderr, err := executeBoth(ctx, tree, nil, "odin", args...)
			out := append(stdout, stderr...)
			if err != nil && !bytes.Contains(out, []byte("error_count")) {
				return diagnostics, fmt.Errorf("odin: %s", tail(strings.TrimSpace(string(out)), 200))
			}
			diagnostics = append(diagnostics, parseOdin(tree, out)...)
		}
		return diagnostics, nil
	},
}

// odinCollections are the -collection flags the repository's ols.json
// declares, which is where an Odin project names the collections its
// imports resolve through; a relative path is relative to the repository.
// Without them the compiler cannot see past `import "name:pkg"`.
func odinCollections(tree string) []string {
	data, err := os.ReadFile(filepath.Join(tree, "ols.json"))
	if err != nil {
		return nil
	}
	var config struct {
		Collections []struct {
			Name string `json:"name"`
			Path string `json:"path"`
		} `json:"collections"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		return nil
	}
	var flags []string
	for _, c := range config.Collections {
		if c.Name == "" || c.Path == "" {
			continue
		}
		path := c.Path
		if !filepath.IsAbs(path) {
			path = filepath.Join(tree, path)
		}
		flags = append(flags, "-collection:"+c.Name+"="+path)
	}
	return flags
}

// parseOdin reads the compiler's -json-errors: a type error is a fault, a
// vet failure the vet's opinion, a style failure a note.
func parseOdin(tree string, out []byte) []Diagnostic {
	var report struct {
		Errors []struct {
			Type string `json:"type"`
			Pos  struct {
				File string `json:"file"`
				Line int    `json:"line"`
			} `json:"pos"`
			Msgs []string `json:"msgs"`
		} `json:"errors"`
	}
	// The compiler prints its own prose before the JSON when it cannot
	// even start; the object is taken from wherever it sits.
	if raw, err := object(string(out)); err == nil {
		json.Unmarshal([]byte(raw), &report)
	}
	var diagnostics []Diagnostic
	for _, e := range report.Errors {
		message := strings.Join(e.Msgs, "; ")
		d := Diagnostic{
			File: filepath.ToSlash(relative(tree, e.Pos.File)), Line: e.Pos.Line,
			Message: message, Severity: MustFix, Fault: true,
		}
		switch {
		case strings.Contains(message, "-strict-style"):
			d.Code, d.Severity, d.Fault = "style", Note, false
		case e.Type == "warning":
			d.Severity, d.Fault = Consider, false
		case strings.Contains(message, "declared but not used"), strings.Contains(message, "shadow"):
			// A vet failure fails the build under -vet, but it is the
			// vet's opinion, not a type error.
			d.Code, d.Severity, d.Fault = "vet", Consider, false
		}
		diagnostics = append(diagnostics, d)
	}
	return diagnostics
}

// tscLine matches the compiler's plain output: file(line,col): error TSnnnn: message.
var tscLine = regexp.MustCompile(`^(.+?)\((\d+),(\d+)\): error (TS\d+): (.*)$`)

// tsc type-checks each project a changed TypeScript file belongs to, under
// the project's own tsconfig — strictness is the project's to set — and
// emits nothing. It needs the project's node_modules, so it reads the
// working tree only.
var tsc = Analyser{
	Name:    "tsc",
	Covers:  func(path string) bool { return grammarOf(path) != "" },
	InPlace: true,
	Ready: func(tree string) (bool, string) {
		if _, err := exec.LookPath("tsc"); err == nil {
			return true, ""
		}
		if _, err := os.Stat(filepath.Join(tree, "node_modules", ".bin", "tsc")); err == nil {
			return true, ""
		}
		return false, ""
	},
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		binary := filepath.Join(tree, "node_modules", ".bin", "tsc")
		if _, err := os.Stat(binary); err != nil {
			binary = "tsc"
		}
		projects := map[string]bool{}
		for _, f := range files {
			if p := nearest(tree, filepath.Dir(f), "tsconfig.json"); p != "" {
				projects[p] = true
			}
		}
		if len(projects) == 0 {
			return nil, fmt.Errorf("no tsconfig.json above the changed files")
		}
		var diagnostics []Diagnostic
		for _, project := range slices.Sorted(func(yield func(string) bool) {
			for p := range projects {
				if !yield(p) {
					return
				}
			}
		}) {
			dir := filepath.Join(tree, filepath.Dir(project))
			out, err := execute(ctx, dir, nil, binary, "--noEmit", "--pretty", "false", "-p", "tsconfig.json")
			if err != nil {
				return diagnostics, err
			}
			diagnostics = append(diagnostics, parseTsc(tree, dir, out)...)
		}
		return diagnostics, nil
	},
}

// parseTsc reads the compiler's plain output, with paths relative to the
// project directory it ran in.
func parseTsc(tree, dir string, out []byte) []Diagnostic {
	var diagnostics []Diagnostic
	for _, line := range strings.Split(string(out), "\n") {
		m := tscLine.FindStringSubmatch(strings.TrimSpace(line))
		if m == nil {
			continue
		}
		file := relative(tree, filepath.Join(dir, filepath.FromSlash(m[1])))
		diagnostics = append(diagnostics, Diagnostic{
			File: filepath.ToSlash(file), Line: atoi(m[2]), Code: m[4], Message: m[5],
			Severity: MustFix, Fault: true,
		})
	}
	return diagnostics
}

// nearest is the path, relative to the tree, of the first file called name
// in dir or a directory above it, or empty.
func nearest(tree, dir, name string) string {
	for {
		candidate := filepath.Join(dir, name)
		if _, err := os.Stat(filepath.Join(tree, candidate)); err == nil {
			return filepath.ToSlash(candidate)
		}
		if dir == "." || dir == "" || dir == "/" {
			return ""
		}
		dir = filepath.Dir(dir)
	}
}

func isPython(path string) bool { return strings.HasSuffix(path, ".py") }

// ruff lints the changed Python files with the project's own configuration
// and reads its JSON. Its style codes are notes; what pyflakes would have
// said is worth considering.
var ruff = Analyser{
	Name:   "ruff",
	Covers: isPython,
	Ready:  onPath("ruff"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		out, err := execute(ctx, tree, nil, "ruff", append([]string{"check", "--output-format", "json", "--exit-zero"}, files...)...)
		if err != nil {
			return nil, err
		}
		return parseRuff(tree, out)
	},
}

// parseRuff reads ruff's JSON array. Style codes — E, W, import order,
// docstrings — are notes; the rest is worth considering.
func parseRuff(tree string, out []byte) ([]Diagnostic, error) {
	var report []struct {
		Code     string `json:"code"`
		Message  string `json:"message"`
		Filename string `json:"filename"`
		Location struct {
			Row int `json:"row"`
		} `json:"location"`
	}
	if err := json.Unmarshal(out, &report); err != nil {
		return nil, fmt.Errorf("ruff: %w", err)
	}
	var diagnostics []Diagnostic
	for _, r := range report {
		severity := Consider
		if strings.HasPrefix(r.Code, "E") || strings.HasPrefix(r.Code, "W") || strings.HasPrefix(r.Code, "I") || strings.HasPrefix(r.Code, "D") {
			severity = Note
		}
		diagnostics = append(diagnostics, Diagnostic{
			File: filepath.ToSlash(relative(tree, r.Filename)), Line: r.Location.Row,
			Code: r.Code, Message: r.Message, Severity: severity,
		})
	}
	return diagnostics, nil
}

// mypy type-checks the changed Python files and reads its JSON, one object
// per line. Imports it cannot find are the environment's business, not the
// change's, and are not reported.
var mypy = Analyser{
	Name:    "mypy",
	Covers:  isPython,
	Ready:   onPath("mypy"),
	InPlace: true,
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		out, err := execute(ctx, tree, nil, "mypy", append([]string{"--output", "json", "--no-error-summary", "--ignore-missing-imports"}, files...)...)
		if err != nil {
			return nil, err
		}
		return parseMypy(tree, out), nil
	},
}

// parseMypy reads mypy's JSON, one object per line: an error is a type
// error and must-fix, anything else a note.
func parseMypy(tree string, out []byte) []Diagnostic {
	var diagnostics []Diagnostic
	for _, line := range bytes.Split(out, []byte("\n")) {
		var r struct {
			File     string `json:"file"`
			Line     int    `json:"line"`
			Message  string `json:"message"`
			Code     string `json:"code"`
			Severity string `json:"severity"`
		}
		if json.Unmarshal(line, &r) != nil || r.File == "" {
			continue
		}
		severity := MustFix
		if r.Severity != "error" {
			severity = Note
		}
		diagnostics = append(diagnostics, Diagnostic{
			File: filepath.ToSlash(relative(tree, r.File)), Line: r.Line,
			Code: r.Code, Message: r.Message, Severity: severity,
		})
	}
	return diagnostics
}

// cargoCheck type-checks each crate a changed Rust file belongs to — with
// clippy where it is installed, which checks and lints in one run — and
// reads the compiler's JSON messages. The target directory is the
// repository's own, so a range's materialised tree reuses the build cache.
var cargoCheck = Analyser{
	Name:   "cargo",
	Covers: func(path string) bool { return strings.HasSuffix(path, ".rs") },
	Ready:  onPath("cargo"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		crates := map[string]bool{}
		for _, f := range files {
			if c := nearest(tree, filepath.Dir(f), "Cargo.toml"); c != "" {
				crates[c] = true
			}
		}
		if len(crates) == 0 {
			return nil, fmt.Errorf("no Cargo.toml above the changed files")
		}
		verb := "check"
		if exec.CommandContext(ctx, "cargo", "clippy", "--version").Run() == nil {
			verb = "clippy"
		}
		var diagnostics []Diagnostic
		for _, crate := range slices.Sorted(func(yield func(string) bool) {
			for c := range crates {
				if !yield(c) {
					return
				}
			}
		}) {
			dir := filepath.Join(tree, filepath.Dir(crate))
			target := filepath.Join(root, filepath.Dir(crate), "target")
			out, err := execute(ctx, dir, []string{"CARGO_TARGET_DIR=" + target}, "cargo", verb, "--message-format", "json", "--quiet")
			if err != nil {
				return diagnostics, err
			}
			diagnostics = append(diagnostics, parseCargo(tree, dir, out)...)
		}
		return diagnostics, nil
	},
}

// parseCargo reads the compiler messages out of cargo's JSON stream, one
// per primary span, with paths relative to the crate directory it ran in.
func parseCargo(tree, dir string, out []byte) []Diagnostic {
	var diagnostics []Diagnostic
	for _, line := range bytes.Split(out, []byte("\n")) {
		var event struct {
			Reason  string `json:"reason"`
			Message struct {
				Level   string `json:"level"`
				Message string `json:"message"`
				Code    *struct {
					Code string `json:"code"`
				} `json:"code"`
				Spans []struct {
					File    string `json:"file_name"`
					Line    int    `json:"line_start"`
					Primary bool   `json:"is_primary"`
				} `json:"spans"`
			} `json:"message"`
		}
		if json.Unmarshal(line, &event) != nil || event.Reason != "compiler-message" {
			continue
		}
		for _, span := range event.Message.Spans {
			if !span.Primary {
				continue
			}
			d := Diagnostic{
				File:    filepath.ToSlash(relative(tree, filepath.Join(dir, filepath.FromSlash(span.File)))),
				Line:    span.Line,
				Message: event.Message.Message,
			}
			if event.Message.Code != nil {
				d.Code = event.Message.Code.Code
			}
			switch event.Message.Level {
			case "error":
				d.Severity, d.Fault = MustFix, true
			case "warning":
				d.Severity = Consider
			default:
				continue
			}
			diagnostics = append(diagnostics, d)
			break
		}
	}
	return diagnostics
}

// semgrepLanguages are the extensions semgrep parses that review's other
// analysers do not already cover with a compiler of their own, and the ones
// they do: semgrep's rules are about patterns, not types, and say things a
// compiler does not.
var semgrepLanguages = []string{
	".go", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".rs", ".java", ".kt", ".kts",
	".rb", ".php", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".swift", ".scala", ".lua",
	".ex", ".exs", ".dart", ".sh", ".bash", ".tf", ".yaml", ".yml", ".json", ".html", ".sol",
}

// semgrepConfig is the rule set semgrep is pointed at: the repository's own
// configuration where it has one — that is the repository's word on what
// matters — and the registry's default pack otherwise, fetched over the
// network. Not `auto`: semgrep refuses to build that selection with metrics
// off, and review never sends metrics.
func semgrepConfig(tree string) string {
	for _, name := range []string{".semgrep.yml", ".semgrep.yaml", ".semgrep"} {
		if _, err := os.Stat(filepath.Join(tree, name)); err == nil {
			return name
		}
	}
	return "p/default"
}

// semgrep runs the pattern analyser over the changed files it can parse,
// and reads its JSON. A rule's severity is the rule author's word on it,
// kept as reported: ERROR must-fix, WARNING consider, INFO note.
var semgrep = Analyser{
	Name: "semgrep",
	Covers: func(path string) bool {
		return hasSuffix(path, semgrepLanguages) && isCodeFile(path) || hasSuffix(path, []string{".yaml", ".yml", ".json", ".html"})
	},
	Ready: onPath("semgrep"),
	Run: func(ctx context.Context, tree, root string, files []string) ([]Diagnostic, error) {
		args := []string{"scan", "--json", "--quiet", "--config", semgrepConfig(tree), "--metrics", "off"}
		out, err := execute(ctx, tree, nil, "semgrep", append(args, files...)...)
		if err != nil {
			return nil, err
		}
		return parseSemgrep(tree, out)
	},
}

// parseSemgrep reads semgrep's JSON report: one result per match, located
// by its start line, with the rule's id and severity.
func parseSemgrep(tree string, out []byte) ([]Diagnostic, error) {
	var report struct {
		Results []struct {
			CheckID string `json:"check_id"`
			Path    string `json:"path"`
			Start   struct {
				Line int `json:"line"`
			} `json:"start"`
			Extra struct {
				Message  string `json:"message"`
				Severity string `json:"severity"`
			} `json:"extra"`
		} `json:"results"`
	}
	if err := json.Unmarshal(out, &report); err != nil {
		return nil, fmt.Errorf("semgrep: %w", err)
	}
	var diagnostics []Diagnostic
	for _, r := range report.Results {
		severity := Note
		switch strings.ToUpper(r.Extra.Severity) {
		case "ERROR", "HIGH", "CRITICAL":
			severity = MustFix
		case "WARNING", "MEDIUM":
			severity = Consider
		}
		file := r.Path
		if filepath.IsAbs(file) {
			file = relative(tree, file)
		}
		diagnostics = append(diagnostics, Diagnostic{
			File: filepath.ToSlash(file), Line: r.Start.Line, Code: r.CheckID,
			Message: strings.TrimSpace(r.Extra.Message), Severity: severity,
		})
	}
	return diagnostics, nil
}
