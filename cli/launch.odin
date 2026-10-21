package cli

import "core:fmt"
import "../mcp"

run_protocol :: proc(args: []string, allocator := context.allocator) -> (code: int, selected: bool) {
	request := launch(args)
	if request.selected {
		if request.error != "" {fmt.eprintln(request.error); return 2, true}
		return mcp.run(request.repo, allocator), true
	}
	if is_external(args) {return run_external(args[1:], allocator), true}
	return 0, false
}

// Launch selects the early protocol server without printing or touching providers.
Launch :: struct {
	selected: bool,
	repo: string,
	error: string,
}

launch :: proc(args: []string) -> Launch {
	if len(args) == 0 || args[0] != "mcp" {return {}}
	if len(args) != 3 || args[1] != "--repo" || args[2] == "" {
		return Launch{selected = true, error = "usage: review mcp --repo <absolute-repository-path>"}
	}
	return Launch{selected = true, repo = args[2]}
}
