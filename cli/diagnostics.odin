package cli

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "../discovery"
import "../git"

json_failure :: proc(enabled: bool, kind, message: string, allocator := context.allocator) {
	if !enabled {return}
	Envelope :: struct {version: int, status, kind, error: string}
	out, _ := json.marshal(Envelope{1, "error", kind, message}, allocator = allocator)
	fmt.println(string(out))
}

// doctor inspects local capability only; credential presence is never an authentication probe.
doctor :: proc(flags: Flags, allocator := context.allocator) -> int {
	Tool :: struct {name, path: string, available: bool}
	Diagnostic :: struct {
		version: int,
		status, repository: string,
		repository_available: bool,
		tools: []Tool,
		api_credential_present: bool,
		authentication_verified: bool,
	}
	cwd, _ := os.get_working_directory(allocator)
	if flags.repo != "" {cwd = flags.repo}
	root, found := git.toplevel(cwd)
	d := Diagnostic{version = 1, status = "diagnostic", repository = root, repository_available = found,
		api_credential_present = os.get_env("ANTHROPIC_API_KEY", allocator) != ""}
	tools := make([dynamic]Tool, allocator)
	names := []string{"git", "review-go", "review-vet", "odin-review-extract", "claude", "grok", "codex", "pi"}
	for name in names {
		path, available := discovery.find(name, allocator)
		append(&tools, Tool{name, path, available})
	}
	d.tools = tools[:]
	out, err := json.marshal(d, allocator = allocator)
	if err != nil {json_failure(flags.as_json, "encoding", "diagnostic could not be encoded"); return 1}
	fmt.println(string(out))
	return 0
}
