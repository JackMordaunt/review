/*
Package frontend reads source files through the language sidecars this
repository ships: review-go for Go and odin-review-extract for Odin. Each
sidecar is that language's own parser printing one JSON answer, so the
reviewer here does not own a grammar. The answer's shape is shared; a field
one language lacks stays zero.
*/
package frontend

import "core:encoding/json"
import "core:strings"
import "jm:sh"

// Decl is one declaration as a sidecar reports it. Kinds are func, type,
// field, const, var and value. A test is what the language's test runner
// runs. A local declaration sits inside a function body.
Decl :: struct {
	name:     string,
	kind:     string,
	line:     int,
	end_line: int,
	exported: bool,
	test:     bool,
	local:    bool,
	text:     string,
	doc:      string,
	// body is the declaration's whole text where the reader has it as
	// one match; empty where the caller reads it from the file by lines.
	body:     string,
}

// Comment is one comment, located by its first line, marker stripped.
Comment :: struct {
	line: int,
	text: string,
}

// File is what one source file declares. An error is a file the sidecar
// could not parse; its lists are then empty rather than missing.
File :: struct {
	name:     string,
	pkg:      string `json:"package"`,
	imports:  []string,
	decls:    []Decl,
	comments: []Comment,
	error:    string,
}

Output :: struct {
	files: []File,
}

// Sidecar names the parser a language is read through: a program built
// on the language's own parser for Go and Odin, and ast-grep's grammars
// for the rest.
Sidecar :: enum {
	Go,
	Odin,
	Script,
	Python,
	Rust,
	Bash,
}

// Scan_Error says why a scan returned nothing: the sidecar is not on the
// path, it exited without an answer, or its answer was not the JSON expected.
Scan_Error :: enum {
	None,
	Not_Installed,
	Failed,
	Unreadable,
}

// binary is the executable a sidecar is found on the path as.
binary :: proc(sidecar: Sidecar) -> string {
	switch sidecar {
	case .Go:
		return "review-go"
	case .Odin:
		return "odin-review-extract"
	case .Script, .Python, .Rust, .Bash:
		return "ast-grep"
	}
	return ""
}

// sidecar_for is the sidecar that reads a path, by its extension, or by
// the shell dialect the caller settled for a script whose name carries
// none. The ast-grep languages are covered only while ast-grep is on the
// path; their files fall to the comment reader otherwise.
sidecar_for :: proc(path: string, shell := "") -> (sidecar: Sidecar, covered: bool) {
	switch {
	case strings.has_suffix(path, ".go"):
		return .Go, true
	case strings.has_suffix(path, ".odin"):
		return .Odin, true
	case grammar_of(path) != "":
		return .Script, installed(.Script)
	case strings.has_suffix(path, ".py"):
		return .Python, installed(.Python)
	case strings.has_suffix(path, ".rs"):
		return .Rust, installed(.Rust)
	case shell != "":
		return .Bash, installed(.Bash)
	}
	return .Go, false
}

// installed reports whether a sidecar can be run.
installed :: proc(sidecar: Sidecar) -> bool {
	_, found := sh.which(binary(sidecar), context.temp_allocator)
	return found
}

// scan asks a sidecar for what the files declare. The files are paths the
// sidecar can read; the answer names each by the path given. Everything
// the answer holds is allocated from allocator.
scan :: proc(
	sidecar: Sidecar,
	files: []string,
	allocator := context.allocator,
) -> (
	out: Output,
	err: Scan_Error,
) {
	if len(files) == 0 {
		return
	}
	if !installed(sidecar) {
		return out, .Not_Installed
	}
	if sidecar != .Go && sidecar != .Odin {
		return grep_scan(sidecar, files, allocator)
	}
	argv := make([]string, len(files) + 1, context.temp_allocator)
	argv[0] = binary(sidecar)
	copy(argv[1:], files)
	r := sh.exec(argv, allocator = allocator)
	if !r.ok && len(r.stdout) == 0 {
		return out, .Failed
	}
	if e := json.unmarshal_string(r.stdout, &out, allocator = allocator); e != nil {
		return out, .Unreadable
	}
	return out, .None
}

// tests are the declarations a file's test runner would run.
tests :: proc(file: File, allocator := context.allocator) -> []Decl {
	found := make([dynamic]Decl, allocator)
	for decl in file.decls {
		if decl.test {
			append(&found, decl)
		}
	}
	return found[:]
}
