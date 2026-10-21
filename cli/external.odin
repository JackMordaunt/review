package cli

import "../external"
import "core:encoding/json"
import "core:fmt"
import "core:os"

is_external :: proc(args: []string) -> bool {
	return len(args) > 0 && args[0] == "external"
}

// run_external owns the external command parser and writes one JSON result.
run_external :: proc(args: []string, allocator := context.allocator) -> int {
	context.allocator = allocator
	out, err := external_result(args)
	if err != "" {
		encoded, _ := json.marshal(struct {
			error: string,
		}{err})
		fmt.println(string(encoded))
		fmt.eprintfln("review: %s", err)
		return 2
	}
	encoded, encode_err := json.marshal(out)
	if encode_err != nil {fmt.println(`{"error":"could not encode external result"}`); return 1}
	fmt.println(string(encoded))
	return 0
}

@(private)
external_result :: proc(
	args: []string,
	allocator := context.allocator,
) -> (
	external.View,
	string,
) {
	context.allocator = allocator
	if len(args) ==
	   0 {return {}, "usage: review external prepare|submit|report --repo DIR [--rev REV] [--jobs LIST] [--run ID]; submit reads JSON on stdin"}
	opts: external.Options
	run_id := ""
	for i := 1; i < len(args); i += 2 {
		if i + 1 >= len(args) {return {}, "missing external option value"}
		switch args[i] {
		case "--repo":
			opts.repo = args[i + 1]
		case "--rev":
			opts.rev = args[i + 1]
		case "--jobs":
			opts.only = args[i + 1]
		case "--run":
			run_id = args[i + 1]
		case:
			return {}, "unknown external option"
		}
	}
	switch args[0] {
	case "prepare":
		if run_id != "" {return {}, "prepare does not accept --run"}
		return external.prepare(opts)
	case "report":
		if run_id == "" ||
		   opts.rev != "" ||
		   opts.only != "" {return {}, "report requires --run and accepts only --repo"}
		return external.inspect(opts.repo, run_id)
	case "submit":
		if run_id != "" ||
		   opts.rev != "" ||
		   opts.only !=
			   "" {return {}, "submit accepts only --repo; identity belongs in its JSON input"}
		data := make([]byte, external.max_answer + 1)
		n := 0
		for n < len(data) {
			got, _ := os.read(os.stdin, data[n:])
			if got == 0 {break}
			n += got
		}
		obj, ok := external.parse_object(string(data[:n]))
		if !ok ||
		   len(obj) !=
			   6 {return {}, "submission requires version, run_id, source_id, job_id, schema and answer"}
		sub: external.Submission
		if json.unmarshal(data[:n], &sub) != nil {return {}, "malformed submission"}
		return external.submit(opts.repo, sub)
	}
	return {}, "unknown external action"
}
