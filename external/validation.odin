package external

import "../job"
import "core:encoding/json"
import "core:strings"

// parse_object rejects trailing data, duplicate keys, JSON5 and excessive nesting.
parse_object :: proc(text: string, allocator := context.allocator) -> (json.Object, bool) {
	context.allocator = allocator
	if len(text) > max_answer {return nil, false}
	depth := 0
	previous: rune
	quoted, escaped := false, false
	for c in text {
		if quoted {
			if escaped {escaped = false} else if c == '\\' {escaped = true} else if c == '"' {quoted = false}
			continue
		}
		if (c == '}' || c == ']') && previous == ',' {return nil, false}
		if c != ' ' && c != '\t' && c != '\r' && c != '\n' {previous = c}
		if c == '"' {quoted = true}
		if c == '{' || c == '[' {depth += 1}
		if c == '}' || c == ']' {depth -= 1}
		if depth > 32 || depth < 0 {return nil, false}
	}
	parser := json.make_parser(text, .JSON, true)
	value, err := json.parse_value(&parser)
	if err != .None || parser.curr_token.kind != .EOF {return nil, false}
	obj, ok := value.(json.Object)
	return obj, ok
}

@(private)
schema_for_answer :: proc(text: string, allocator := context.allocator) -> string {
	context.allocator = allocator
	obj, ok := parse_object(text)
	if !ok {return ""}
	if _, present := obj["findings"]; present {return "review.findings.v1"}
	return "review.verdicts.v1"
}

@(private)
validate_answer :: proc(
	packet: Packet,
	text: string,
	files: []string,
	allocator := context.allocator,
) -> string {
	context.allocator = allocator
	obj, parsed := parse_object(text)
	if !parsed ||
	   len(obj) != 1 {return "answer must be one strict JSON object matching the job schema"}
	key := "findings" if packet.schema == "review.findings.v1" else "verdicts"
	items, array := obj[key].(json.Array)
	if !array || len(items) > 256 {return "answer requires a bounded findings or verdicts array"}
	if key == "findings" {
		allowed := job.rules(packet.system)
		for item in items {
			f, object := item.(json.Object)
			if !object {return "finding must be an object"}
			for name, value in f {
				if name == "line" {
					line, integer := value.(json.Integer)
					if !integer ||
					   line < 0 ||
					   line > 10000000 {return "finding line must be a nonnegative integer"}
					continue
				}
				switch name {
				case "rule", "severity", "file", "symbol", "message", "fix":
					if _, string_value := value.(string);
					   !string_value {return "finding fields must be strings"}
				case:
					return "unknown finding field"
				}
			}
			required := [?]string{"rule", "severity", "message"}
			for name in required {
				value, present := f[name].(string)
				if !present ||
				   strings.trim_space(value) ==
					   "" {return "finding requires rule, severity and message"}
			}
			if !allowed[f["rule"].(string)] {return "finding rule does not belong to this job"}
			severity := f["severity"].(string)
			if severity != "must-fix" &&
			   severity != "consider" &&
			   severity != "note" {return "invalid finding severity"}
			if file, present := f["file"].(string); present && file != "" {
				known := false
				for changed in files {if changed == file {known = true}}
				if !known {return "finding file is outside the reviewed change"}
			}
		}
		return ""
	}
	// The engine supplies the count; rendered evidence and messages are untrusted.
	count := packet.verdict_count
	if len(items) != count {return "verification must judge every finding"}
	seen: [256]bool
	for item in items {
		v, object := item.(json.Object)
		if !object || len(v) != 3 {return "verdict requires index, holds and reason"}
		index, integer := v["index"].(json.Integer)
		_, boolean := v["holds"].(bool)
		_, string_value := v["reason"].(string)
		if !integer ||
		   !boolean ||
		   !string_value ||
		   index < 0 ||
		   index >= i64(count) ||
		   seen[index] {
			return "invalid or duplicate verdict index, holds or reason"
		}
		seen[index] = true
	}
	return ""
}
