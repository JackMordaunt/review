package mcp

import "../external"
import "../git"
import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"

repository: string

run :: proc(repo: string, allocator := context.allocator) -> int {
	context.allocator = allocator
	if !filepath.is_abs(repo) {
		fmt.eprintln("review mcp: expected --repo /absolute/git/repository"); return 2
	}
	root, ok := git.toplevel(repo)
	if !ok {fmt.eprintln("review mcp: repository unavailable:", root); return 2}
	repository = root
	s := Session {
		handler = call_engine,
	}
	if json.unmarshal_string(TOOLS, &s.tools, spec = .JSON) !=
	   nil {fmt.eprintln("review mcp: invalid tool definitions"); return 1}
	return serve(&s)
}

call_engine :: proc(
	name: string,
	args: json.Object,
	allocator := context.allocator,
) -> (
	json.Value,
	string,
) {
	context.allocator = allocator
	view: external.View
	err: string
	switch name {
	case "review_prepare":
		view, err = external.prepare(
			{repo = repository, rev = str(args["rev"]), only = str(args["only"])},
		)
	case "review_submit":
		if len(args) != 6 {return nil, "All submission fields are required"}
		sub: external.Submission
		if json.unmarshal_string(encode(args), &sub, spec = .JSON) !=
		   nil {return nil, "Invalid submission"}
		view, err = external.submit(repository, sub)
	case "review_report":
		if len(args) != 1 || str(args["run_id"]) == "" {return nil, "run_id is required"}
		view, err = external.inspect(repository, str(args["run_id"]))
	}
	if err != "" {return nil, err}
	result, ok := parse(encode(view))
	if !ok {return nil, "Could not encode engine result"}
	return result, ""
}

// validate_call enforces the advertised input schemas before engine execution.
//review:ignore verb-for-func validate_call begins with the verb validate.
validate_call :: proc(name: string, args: json.Object, allocator := context.allocator) -> string {
	context.allocator = allocator
	// Decode only after exact key validation; repo cannot be overridden by a tool.
	prepare_keys := [?]string{"rev", "only"}
	submit_keys := [?]string{"version", "run_id", "source_id", "job_id", "schema", "answer"}
	report_keys := [?]string{"run_id"}
	keys := []string{}
	switch name {
	case "review_prepare":
		keys = prepare_keys[:]
	case "review_submit":
		keys = submit_keys[:]
	case "review_report":
		keys = report_keys[:]
	case:
		return "Unknown tool"
	}
	for k, v in args {
		found := false
		for allowed in keys {if k == allowed {found = true}}
		if !found {return "Unknown argument"}
		if k ==
		   "version" {if _, ok := v.(i64); !ok {return "version must be an integer"}} else if _, ok := v.(string); !ok {return "Argument must be a string"}
	}

	if name == "review_submit" {
		if len(args) != 6 {return "All submission fields are required"}
		version, _ := args["version"].(i64)
		if version != 1 {return "version must equal 1"}
		if len(str(args["answer"])) > 256 * 1024 {return "answer exceeds 256 KiB"}
	}
	if name == "review_report" &&
	   (len(args) != 1 || str(args["run_id"]) == "") {return "run_id is required"}
	return ""
}

TOOLS :: `[
{"name":"review_prepare","description":"Prepare a review without inference. Read every returned job's system and user instructions, produce its schema answer, and submit each job. Repeat for verification jobs; pending work is incomplete.","outputSchema":{"type":"object","properties":{"version":{"type":"integer"},"run_id":{"type":"string"},"source_id":{"type":"string"},"repo":{"type":"string"},"jobs":{"type":"array","items":{"type":"object","properties":{"job_id":{"type":"string"},"schema":{"type":"string"},"system":{"type":"string"},"user":{"type":"string"},"verdict_count":{"type":"integer"}},"required":["job_id","schema","system","user","verdict_count"]}},"report":{"type":"object"}},"required":["version","run_id","source_id","repo","jobs","report"]},"inputSchema":{"type":"object","properties":{"rev":{"type":"string"},"only":{"type":"string"}},"additionalProperties":false}},
{"name":"review_submit","description":"Submit the assistant's JSON answer as a string using the packet's exact identities and schema. Inspect returned jobs for required verification.","outputSchema":{"type":"object","properties":{"version":{"type":"integer"},"run_id":{"type":"string"},"source_id":{"type":"string"},"repo":{"type":"string"},"jobs":{"type":"array","items":{"type":"object","properties":{"job_id":{"type":"string"},"schema":{"type":"string"},"system":{"type":"string"},"user":{"type":"string"},"verdict_count":{"type":"integer"}},"required":["job_id","schema","system","user","verdict_count"]}},"report":{"type":"object"}},"required":["version","run_id","source_id","repo","jobs","report"]},"inputSchema":{"type":"object","properties":{"version":{"type":"integer","const":1},"run_id":{"type":"string"},"source_id":{"type":"string"},"job_id":{"type":"string"},"schema":{"type":"string"},"answer":{"type":"string","maxLength":262144}},"required":["version","run_id","source_id","job_id","schema","answer"],"additionalProperties":false}},
{"name":"review_report","description":"Read the persisted review and pending jobs. Only the report's explicit completion status establishes completion.","outputSchema":{"type":"object","properties":{"version":{"type":"integer"},"run_id":{"type":"string"},"source_id":{"type":"string"},"repo":{"type":"string"},"jobs":{"type":"array","items":{"type":"object","properties":{"job_id":{"type":"string"},"schema":{"type":"string"},"system":{"type":"string"},"user":{"type":"string"},"verdict_count":{"type":"integer"}},"required":["job_id","schema","system","user","verdict_count"]}},"report":{"type":"object"}},"required":["version","run_id","source_id","repo","jobs","report"]},"inputSchema":{"type":"object","properties":{"run_id":{"type":"string"}},"required":["run_id"],"additionalProperties":false}}
]`
