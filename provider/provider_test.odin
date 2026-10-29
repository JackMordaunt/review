package provider

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "jm:path"

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
	testing.expect_value(t, name(Provider{kind = .Codex}, context.temp_allocator), "codex")
	testing.expect_value(
		t,
		name(Provider{kind = .Codex, model = "gpt-5"}, context.temp_allocator),
		"codex/gpt-5",
	)
	c, ok_codex := build("codex", "", context.temp_allocator)
	testing.expect(t, ok_codex)
	testing.expect_value(t, c.model, "")
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
	testing.expect_value(t, len(chain), 5)
	testing.expect_value(t, chain[0].provider.kind, Kind.Api)
	testing.expect_value(t, chain[1].name, "claude/sonnet")
	testing.expect_value(t, chain[2].provider.kind, Kind.Grok)
	testing.expect_value(t, chain[2].name, "grok/grok-4.7")
	testing.expect_value(t, chain[3].name, "codex")
	testing.expect_value(t, chain[3].provider.kind, Kind.Codex)
	testing.expect_value(t, chain[4].provider.kind, Kind.Pi)
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
	structured, structured_err := read_grok(
		`{"text":"I'll check those findings.","structuredOutput":{"verdicts":[{"index":0,"holds":false,"reason":"the assertion checks the stated contract"}]},"stopReason":"end_turn"}`,
		context.temp_allocator,
	)
	testing.expect_value(t, structured_err, "")
	testing.expect(t, strings.contains(structured.text, `"verdicts"`))
	testing.expect(t, !strings.contains(structured.text, "I'll check"))
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

@(test)
codex_answers_from_its_last_message :: proc(t: ^testing.T) {
	events := `{"type":"thread.started","thread_id":"x"}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}}
`
	answer, err := read_codex(events, `{"findings":[]}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, answer.text, `{"findings":[]}`)
	testing.expect_value(t, answer.tokens_in, 10)
	testing.expect_value(t, answer.cached, 4)
	testing.expect_value(t, answer.tokens_out, 2)
	failed := `{"type":"error","message":"usage limit"}
{"type":"turn.failed","error":{"message":"usage limit"}}
`
	_, err = read_codex(failed, "", context.temp_allocator, "codex: exit 1: noise")
	testing.expect_value(t, err, "usage limit")
	_, err = read_codex("", "", context.temp_allocator, "codex: exit 1: noise")
	testing.expect_value(t, err, "codex: exit 1: noise")
	_, err = read_codex("", "  \n", context.temp_allocator)
	testing.expect_value(t, err, "answered nothing")
}

@(test)
grok_asks_from_a_home_of_its_own :: proc(t: ^testing.T) {
	env := grok_environment("/nonexistent-review-test")
	want := strings.concatenate(
		{"GROK_HOME=", path.join("/nonexistent-review-test", "home", allocator = context.temp_allocator)},
		context.temp_allocator,
	)
	homes := 0
	for kv in env {
		if strings.has_prefix(kv, want) {
			homes += 1
		}
	}
	testing.expect_value(t, homes, 1)
	testing.expect(t, slice.contains(env, "GROK_CLAUDE_HOOKS_ENABLED=0"))
	testing.expect(t, slice.contains(env, "GROK_MEMORY=0"))
}

@(test)
an_unset_key_is_passed_over_quietly :: proc(t: ^testing.T) {
	saved := os.get_env("ANTHROPIC_API_KEY", context.temp_allocator)
	os.unset_env("ANTHROPIC_API_KEY")
	defer if saved != "" {os.set_env("ANTHROPIC_API_KEY", saved)}

	@(static) warned: int
	warned = 0
	chain := []Entry{{"api/claude-sonnet-5", Provider{kind = .Api, model = "claude-sonnet-5"}}}
	_, _, err := pick(chain, proc(msg: string) {warned += 1}, context.temp_allocator)
	testing.expect_value(t, warned, 0)
	testing.expect(t, strings.contains(err, "api/claude-sonnet-5: ANTHROPIC_API_KEY is not set"), err)
}
