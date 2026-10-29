package provider

// The console API enforces the answer's shape through a strict tool.
// The tool's input is the answer.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "jm:http"

api_url     :: "https://api.anthropic.com/v1/messages"
api_version :: "2023-06-01"

// Tool is the strict shape one ask is held to.
Tool :: struct {
	name, description, schema: string,
}

// findings_tool is the shape a finding takes.
findings_tool := Tool {
	"report_findings",
	"Report what this reading found, or an empty list.",
	`{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"rule":{"type":"string","description":"the rule id from the criteria"},"severity":{"type":"string","enum":["must-fix","consider","note"]},"file":{"type":"string"},"line":{"type":"integer"},"symbol":{"type":"string"},"message":{"type":"string","description":"one sentence stating the finding"},"fix":{"type":"string","description":"the concrete change to make"}},"required":["rule","severity","message","fix","file","line","symbol"],"additionalProperties":false}}},"required":["findings"],"additionalProperties":false}`,
}

// verdicts_tool is the shape the second reading answers in.
verdicts_tool := Tool {
	"report_verdicts",
	"Report whether each finding holds.",
	`{"type":"object","properties":{"verdicts":{"type":"array","items":{"type":"object","properties":{"index":{"type":"integer","description":"the number of the finding, as it was listed"},"holds":{"type":"boolean","description":"whether the finding stands against the criteria"},"reason":{"type":"string","description":"why it holds or falls, one sentence"}},"required":["index","holds","reason"],"additionalProperties":false}}},"required":["verdicts"],"additionalProperties":false}`,
}

// request is the body of one ask: the criteria as the system prompt,
// where the API caches them; the temperature pinned, because a loop
// between two models cannot converge if one of them answers differently
// each time it is asked.
request :: proc(
	model, system, user: string,
	tool: Tool,
	allocator := context.allocator,
) -> string {
	return strings.concatenate(
		{
			`{"model":`,
			quote(model),
			`,"max_tokens":4096,"temperature":0,"system":[{"type":"text","text":`,
			quote(system),
			`,"cache_control":{"type":"ephemeral"}}],"tools":[{"name":`,
			quote(tool.name),
			`,"description":`,
			quote(tool.description),
			`,"strict":true,"input_schema":`,
			tool.schema,
			`}],"messages":[{"role":"user","content":[{"type":"text","text":`,
			quote(user),
			`}]}]}`,
		},
		allocator,
	)
}

// quote is a string as JSON writes it.
quote :: proc(s: string) -> string {
	data, err := json.marshal(s, allocator = context.temp_allocator)
	if err != nil {
		return `""`
	}
	return string(data)
}

// ask_api puts one question with one strict tool. The key is the
// environment's, as the SDKs read it.
ask_api :: proc(
	p: Provider,
	system, user: string,
	tool: Tool,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	key := os.get_env("ANTHROPIC_API_KEY", context.temp_allocator)
	if key == "" {
		return {}, "no Anthropic credentials found: ANTHROPIC_API_KEY is not set"
	}
	body := request(p.model, system, user, tool, context.temp_allocator)
	res, err := http.post(
		api_url,
		body,
		"application/json",
		{
			headers = {
				strings.concatenate({"x-api-key: ", key}, context.temp_allocator),
				strings.concatenate({"anthropic-version: ", api_version}, context.temp_allocator),
			},
			timeout = time.Duration(ask_timeout_seconds()) * time.Second,
		},
		context.temp_allocator,
	)
	if err != .None {
		return {}, fmt.aprintf("api: %v", err, allocator = allocator)
	}
	if !res.ok {
		return {}, fmt.aprintf("api: HTTP %d: %s", res.status, first(error_of(res.body), 200), allocator = allocator)
	}
	return reply(res.body, allocator)
}

// error_of is the message an API error carries, or the body whole.
error_of :: proc(body: string) -> string {
	Failure :: struct {
		error: struct {
			message: string `json:"message"`,
		} `json:"error"`,
	}
	f: Failure
	if json.unmarshal_string(body, &f, allocator = context.temp_allocator) == nil &&
	   f.error.message != "" {
		return f.error.message
	}
	return body
}

// reply reads the tool's input out of the API's answer, which is the
// answer, and the usage beside it.
reply :: proc(body: string, allocator := context.allocator) -> (Answer, string) {
	Response :: struct {
		content: []struct {
			type: string `json:"type"`,
		} `json:"content"`,
		usage:   struct {
			tokens_in:  int `json:"input_tokens"`,
			tokens_out: int `json:"output_tokens"`,
			cached:     int `json:"cache_read_input_tokens"`,
		} `json:"usage"`,
	}
	r: Response
	if json.unmarshal_string(body, &r, allocator = context.temp_allocator) != nil {
		return {}, "api: the answer is not the JSON expected"
	}
	answer := Answer {
		tokens_in  = r.usage.tokens_in,
		tokens_out = r.usage.tokens_out,
		cached     = r.usage.cached,
	}
	for block in r.content {
		if block.type == "tool_use" {
			if input, found := tool_input(body); found {
				answer.text = strings.clone(input, allocator)
				return answer, ""
			}
		}
	}
	return answer, "the model answered without reporting"
}

// tool_input is the text of the first "input" object in the answer, as
// the API wrote it, which is the report the tool was held to.
tool_input :: proc(body: string) -> (string, bool) {
	marker :: `"input":`
	at := strings.index(body, marker)
	if at < 0 {
		return "", false
	}
	start := at + len(marker)
	for start < len(body) && (body[start] == ' ' || body[start] == '\n' || body[start] == '\t') {
		start += 1
	}
	if start >= len(body) || body[start] != '{' {
		return "", false
	}
	depth := 0
	in_string := false
	for i := start; i < len(body); i += 1 {
		c := body[i]
		switch {
		case in_string:
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
		case c == '"':
			in_string = true
		case c == '{':
			depth += 1
		case c == '}':
			depth -= 1
			if depth == 0 {
				return body[start:i + 1], true
			}
		}
	}
	return "", false
}
