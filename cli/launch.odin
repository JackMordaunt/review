package cli

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
