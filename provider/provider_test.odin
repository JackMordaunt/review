package provider

import "core:strings"
import "core:testing"

@(test)
names_carry_the_model :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		name(Provider{kind = .Claude, model = "sonnet"}, context.temp_allocator),
		"claude/sonnet",
	)
	testing.expect_value(
		t,
		name(Provider{kind = .Pi, model = "glm", upstream = "maple"}, context.temp_allocator),
		"pi/maple/glm",
	)
	testing.expect_value(t, name(Provider{kind = .Pi}, context.temp_allocator), "pi")
	testing.expect_value(
		t,
		name(Provider{kind = .Api, model = "claude-sonnet-5"}, context.temp_allocator),
		"api/claude-sonnet-5",
	)
	testing.expect_value(
		t,
		name(Provider{kind = .Grok, model = "grok-4.7"}, context.temp_allocator),
		"grok/grok-4.7",
	)
	g, ok_grok := build("grok", "", context.temp_allocator)
	testing.expect(t, ok_grok)
	testing.expect_value(t, g.model, default_grok_model)
	testing.expect_value(
		t,
		name(Provider{kind = .Command, argv = {"echo", "x"}}, context.temp_allocator),
		"command: echo x",
	)
	p, ok := build("api", "", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, p.model, default_api_model)
	_, ok = build("nothing", "", context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
the_chain_tries_the_assistant_between_api_and_gateway :: proc(t: ^testing.T) {
	chain := default_chain(context.temp_allocator)
	testing.expect_value(t, len(chain), 4)
	testing.expect_value(t, chain[0].provider.kind, Kind.Api)
	testing.expect_value(t, chain[1].name, "claude/sonnet")
	testing.expect_value(t, chain[2].provider.kind, Kind.Grok)
	testing.expect_value(t, chain[2].name, "grok/grok-4.7")
	testing.expect_value(t, chain[3].provider.kind, Kind.Pi)
}

@(test)
pi_answers_from_its_stream :: proc(t: ^testing.T) {
	out := `{"type":"message_start"}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"findings\":[]}"}],"usage":{"input":10,"output":2,"cacheRead":1,"cost":{"total":0.5}},"stopReason":"stop"}}
`
	answer, err := spoken(out, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, `{"findings":[]}`)
	testing.expect_value(t, answer.tokens_in, 10)
	testing.expect_value(t, answer.cost, 0.5)
	_, err = spoken("Error: no provider\nmore prose\n", context.temp_allocator)
	testing.expect_value(t, err, "Error: no provider more prose")
	_, err = spoken(
		`{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"rate limited"}}`,
		context.temp_allocator,
	)
	testing.expect_value(t, err, "rate limited")
}

@(test)
grok_answers_from_its_envelope :: proc(t: ^testing.T) {
	answer, err := read_grok(
		`{"text":"{\"findings\":[]}","stopReason":"end_turn","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":1},"total_cost_usd":0.5}`,
		context.temp_allocator,
	)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, `{"findings":[]}`)
	testing.expect_value(t, answer.tokens_in, 10)
	testing.expect_value(t, answer.cached, 1)
	testing.expect_value(t, answer.cost, 0.5)
	_, err = read_grok(`{"type":"error","message":"Couldn't start session"}`, context.temp_allocator)
	testing.expect_value(t, err, "Couldn't start session")
	_, err = read_grok(`{"text":"","stopReason":"max_turn_requests"}`, context.temp_allocator)
	testing.expect_value(t, err, "max_turn_requests")
	_, err = read_grok("not json", context.temp_allocator)
	testing.expect_value(t, err, "reading the answer: not the JSON envelope expected")
}

@(test)
command_answers_whole_or_by_field :: proc(t: ^testing.T) {
	p := Provider {
		kind = .Command,
		argv = {"cat"},
	}
	answer, err := ask(p, "system", "user", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, "system\n\nuser")
	fielded := Provider {
		kind  = .Command,
		argv  = {"echo", `{"answer":"hello","other":1}`},
		field = "answer",
	}
	answer, err = ask(fielded, "s", "u", context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, "hello")
	testing.expect_value(t, field("not json", "answer", context.temp_allocator), "not json")
	_, err = ask(Provider{kind = .Command}, "s", "u", context.temp_allocator)
	testing.expect(t, strings.contains(err, "names no command"))
	_, err = ask(p, "s", "  \n", context.temp_allocator)
	testing.expect_value(t, err, "nothing to ask: the prompt is empty")
	_, err = ask(Provider{kind = .Command, argv = {"false"}}, "s", "u", context.temp_allocator)
	testing.expect(t, strings.contains(err, "exit 1"))
}

@(test)
api_requests_and_replies_are_shaped :: proc(t: ^testing.T) {
	body := request(
		"claude-sonnet-5",
		"sys \"quoted\"",
		"user\nline",
		findings_tool,
		context.temp_allocator,
	)
	for want in ([]string{`"model":"claude-sonnet-5"`, `"text":"sys \"quoted\""`, `"cache_control":{"type":"ephemeral"}`, `"strict":true`, `"name":"report_findings"`, `"text":"user\nline"`, `"temperature":0`}) {
		testing.expectf(t, strings.contains(body, want), "%s missing from %s", want, body)
	}
	answer, err := reply(
		`{"content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"x","name":"report_findings","input":{"findings":[{"rule":"a","message":"b}"}]}}],"usage":{"input_tokens":5,"output_tokens":3,"cache_read_input_tokens":2}}`,
		context.temp_allocator,
	)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, `{"findings":[{"rule":"a","message":"b}"}]}`)
	testing.expect_value(t, answer.tokens_in, 5)
	testing.expect_value(t, answer.cached, 2)
	_, err = reply(`{"content":[{"type":"text","text":"hi"}],"usage":{}}`, context.temp_allocator)
	testing.expect_value(t, err, "the model answered without reporting")
	testing.expect_value(t, error_of(`{"error":{"message":"bad key"}}`), "bad key")
}
