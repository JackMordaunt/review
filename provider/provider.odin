/*
Package provider answers a question. What answers it is not this tool's
business: a console API, a coding assistant on the path, or anything else
that takes a prompt and returns text. Findings are read out of that text
by the caller, so every provider answers the same way whether or not it
can enforce a schema.
*/
package provider

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import "jm:path"
import "jm:sh"

// Answer is what a provider returned, with whatever it could say about
// the cost. A provider that reports no usage leaves the counts at zero
// rather than inventing them. replayed marks an answer the cache
// remembered rather than asked for: it cost nothing this run.
Answer :: struct {
	text:       string,
	tokens_in:  int,
	tokens_out: int,
	cached:     int,
	cost:       f64,
	replayed:   bool,
}

// Kind is which way a provider is asked.
Kind :: enum {
	Claude,
	Pi,
	Grok,
	Codex,
	Api,
	Command,
}

// Provider is one way of asking: the coding assistant claude in its
// non-interactive mode, the assistant pi through one of its upstreams,
// the grok and codex assistants on the path, the console API directly, or
// whatever command the environment names.
Provider :: struct {
	kind:     Kind,
	model:    string,
	upstream: string,
	argv:     []string,
	field:    string,
}

// The default models: the middle one rather than the smallest. Measured
// against the eval set, the smallest reads the shortlist and reports the
// first duplicate it finds rather than all of them.
default_claude_model :: "sonnet"
default_api_model    :: "claude-sonnet-5"
default_grok_model   :: "grok-4.7"

// Observed: an empty --tools is ignored, and a name grok does not know
// restores the full set, which would let a review edit the tree under
// always-approve. Naming one real tool makes the allowlist stick; denying
// that same tool, and the MCP meta-tools an allowlist keeps, leaves none.
grok_tools  :: "todo_write"
grok_denied :: "todo_write,search_tool,use_tool,Agent"

// build is the provider called by name, with the model given or its
// default. The command provider reads its command line from REVIEW_COMMAND
// and the field its answer arrives in from REVIEW_COMMAND_FIELD.
build :: proc(which, model: string, allocator := context.allocator) -> (p: Provider, ok: bool) {
	switch which {
	case "claude":
		return Provider{kind = .Claude, model = model if model != "" else default_claude_model},
			true
	case "pi":
		return Provider {
				kind = .Pi,
				model = model,
				upstream = os.get_env("REVIEW_PI_PROVIDER", allocator),
			},
			true
	case "grok":
		return Provider{kind = .Grok, model = model if model != "" else default_grok_model}, true
	case "codex":
		return Provider{kind = .Codex, model = model}, true
	case "api":
		return Provider{kind = .Api, model = model if model != "" else default_api_model}, true
	case "command":
		return Provider {
				kind = .Command,
				argv = strings.fields(os.get_env("REVIEW_COMMAND", allocator), allocator),
				field = os.get_env("REVIEW_COMMAND_FIELD", allocator),
			},
			true
	}
	return {}, false
}

// name is how a provider is asked for, and what the answer cache keys on:
// it carries the model and the upstream, so that two asks through
// differently pointed providers are never confused.
name :: proc(p: Provider, allocator := context.allocator) -> string {
	switch p.kind {
	case .Claude:
		return strings.concatenate({"claude/", p.model}, allocator)
	case .Grok:
		return strings.concatenate({"grok/", p.model}, allocator)
	case .Codex:
		if p.model == "" {
			return strings.clone("codex", allocator)
		}
		return strings.concatenate({"codex/", p.model}, allocator)
	case .Pi:
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, "pi")
		if p.upstream != "" {
			append(&parts, p.upstream)
		}
		if p.model != "" {
			append(&parts, p.model)
		}
		return strings.join(parts[:], "/", allocator)
	case .Api:
		return strings.concatenate({"api/", p.model}, allocator)
	case .Command:
		if len(p.argv) == 0 {
			return strings.clone("command", allocator)
		}
		return strings.concatenate(
			{"command: ", strings.join(p.argv, " ", context.temp_allocator)},
			allocator,
		)
	}
	return ""
}

// ask puts one question and returns what came back, as text, or why it
// could not.
ask :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	if strings.trim_space(user) == "" {
		return {}, "nothing to ask: the prompt is empty"
	}
	switch p.kind {
	case .Claude:
		return ask_claude(p, system, user, allocator)
	case .Pi:
		return ask_pi(p, system, user, allocator)
	case .Grok:
		return ask_grok(p, system, user, findings_tool.schema, allocator)
	case .Codex:
		return ask_codex(p, system, user, allocator)
	case .Api:
		return ask_api(p, system, user, findings_tool, allocator)
	case .Command:
		return ask_command(p, system, user, allocator)
	}
	return {}, "no such provider"
}

// ask_verdict is the second reading's ask: held to its shape where the
// provider can enforce one, described in the prompt where it cannot.
ask_verdict :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	if strings.trim_space(user) == "" {
		return {}, "nothing to ask: the prompt is empty"
	}
	if p.kind == .Api {
		return ask_api(p, system, user, verdicts_tool, allocator)
	}
	if p.kind == .Grok {
		return ask_grok(p, system, user, verdicts_tool.schema, allocator)
	}
	return ask(p, system, user, allocator)
}

// ask_claude asks the coding assistant on the path, in its non-interactive
// mode, with whatever credentials it already holds. The tools are refused
// rather than left to judgement: these jobs are given everything they may
// read, and a reader that goes looking for more is answering a different
// question from the one asked.
ask_claude :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	out, err := shell(
		{
			"claude",
			"-p",
			"--model",
			p.model,
			"--output-format",
			"json",
			"--disallowedTools",
			"Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit",
			"--append-system-prompt",
			system,
		},
		user,
		context.temp_allocator,
	)
	if err != "" {
		return {}, strings.clone(err, allocator)
	}
	Envelope :: struct {
		result:   string `json:"result"`,
		is_error: bool `json:"is_error"`,
		cost:     f64 `json:"total_cost_usd"`,
		usage:    struct {
			tokens_in:  int `json:"input_tokens"`,
			tokens_out: int `json:"output_tokens"`,
			cached:     int `json:"cache_read_input_tokens"`,
		} `json:"usage"`,
	}
	envelope: Envelope
	if json.unmarshal_string(out, &envelope, allocator = context.temp_allocator) != nil {
		return {}, "reading the answer: not the JSON envelope expected"
	}
	if envelope.is_error {
		return {}, strings.clone(strings.trim_space(envelope.result), allocator)
	}
	return Answer {
			text = strings.clone(envelope.result, allocator),
			tokens_in = envelope.usage.tokens_in,
			tokens_out = envelope.usage.tokens_out,
			cached = envelope.usage.cached,
			cost = envelope.cost,
		},
		""
}

// ask_pi asks the assistant of that name, which speaks to several
// providers of its own; the upstream is named through the environment,
// since which one is reachable is a property of the machine. Its answer
// arrives as a stream of events, not as one envelope.
ask_pi :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	args := make([dynamic]string, context.temp_allocator)
	append(
		&args,
		"pi",
		"-p",
		"--mode",
		"json",
		"--no-session",
		"--no-tools",
		"--system-prompt",
		system,
	)
	if p.upstream != "" {
		append(&args, "--provider", p.upstream)
	}
	if p.model != "" {
		append(&args, "--model", p.model)
	}
	out, err := shell(args[:], user, context.temp_allocator)
	if err != "" {
		return {}, strings.clone(err, allocator)
	}
	return spoken(out, allocator)
}

// Pi_Event is one line of pi's event stream.
Pi_Event :: struct {
	type:    string `json:"type"`,
	message: struct {
		role:          string `json:"role"`,
		content:       []struct {
			type: string `json:"type"`,
			text: string `json:"text"`,
		} `json:"content"`,
		usage:         struct {
			input:      int `json:"input"`,
			output:     int `json:"output"`,
			cache_read: int `json:"cacheRead"`,
			cost:       struct {
				total: f64 `json:"total"`,
			} `json:"cost"`,
		} `json:"usage"`,
		stop_reason:   string `json:"stopReason"`,
		error_message: string `json:"errorMessage"`,
	} `json:"message"`,
}

// spoken reads pi's answer out of its event stream, one JSON object per
// line. The last assistant message is the answer; everything before it is
// the working. Whatever pi says outside the stream is the only clue to a
// refusal, so it is kept for the error.
spoken :: proc(out: string, allocator := context.allocator) -> (Answer, string) {
	answer: Answer
	said := false
	prose := make([dynamic]string, context.temp_allocator)
	rest := out
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" {
			continue
		}
		event: Pi_Event
		if json.unmarshal_string(line, &event, allocator = context.temp_allocator) != nil {
			append(&prose, line)
			continue
		}
		if event.type != "message_end" || event.message.role != "assistant" {
			continue
		}
		if event.message.stop_reason == "error" {
			why :=
				event.message.error_message if event.message.error_message != "" else "the model stopped with an error"
			return {}, strings.clone(why, allocator)
		}
		text := strings.builder_make(allocator)
		for block in event.message.content {
			if block.type == "text" {
				strings.write_string(&text, block.text)
			}
		}
		usage := event.message.usage
		answer = Answer {
			text       = strings.to_string(text),
			tokens_in  = usage.input,
			tokens_out = usage.output,
			cached     = usage.cache_read,
			cost       = usage.cost.total,
		}
		said = true
	}
	if !said {
		why := first(strings.join(prose[:], " ", context.temp_allocator), 200)
		return {}, strings.clone(why if why != "" else "no assistant message in the answer", allocator)
	}
	return answer, ""
}

// ask_grok asks the grok assistant on the path. Its headless guide says a
// prompt is not read from stdin, so the question is written to a file.
// The tool flags leave none callable: these jobs are given everything
// they may read, and a reader that goes looking for more is answering a
// different question, with the tree open under the user's permission mode.
// Observed with grok 1.0.62: it runs the user's own hooks, memory and
// instructions in every session, and a Stop hook that adds context made it
// answer twice ("{...}{...}"), so the ask runs from a home of its own that
// holds only the credential.
ask_grok :: proc(
	p: Provider,
	system, user, schema: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	dir, mk_err := path.temp_dir("review-grok-", context.temp_allocator)
	if mk_err != nil {
		return {}, "grok: could not make a prompt file"
	}
	defer os.remove_all(dir)
	prompt := path.join(dir, "prompt", allocator = context.temp_allocator)
	if os.write_entire_file(prompt, transmute([]byte)user) != nil {
		return {}, "grok: could not write the prompt"
	}
	out, err := shell(
		{
			"grok",
			"--prompt-file",
			prompt,
			"--model",
			p.model,
			"--output-format",
			"json",
			"--json-schema",
			schema,
			"--system-prompt-override",
			system,
			"--verbatim",
			"--max-turns",
			"1",
			"--no-subagents",
			"--disable-web-search",
			"--tools",
			grok_tools,
			"--disallowed-tools",
			grok_denied,
		},
		"",
		context.temp_allocator,
		grok_environment(dir),
	)
	if err != "" {
		return {}, strings.clone(err, allocator)
	}
	return read_grok(out, allocator)
}

// grok_environment is the environment of a grok ask: the caller's, with a
// home of its own under dir that carries the credential and nothing else,
// and the discovery of the Claude files, memory and updates turned off.
// The credential is linked rather than copied so that a refreshed token
// lands where grok keeps it; a file system that refuses the link gets a copy.
grok_environment :: proc(dir: string, allocator := context.temp_allocator) -> []string {
	home := path.join(dir, "home", allocator = allocator)
	if path.mkdirs(home) == nil {
		source := path.join(grok_home(allocator), "auth.json", allocator = allocator)
		target := path.join(home, "auth.json", allocator = allocator)
		if os.symlink(source, target) != nil {
			if data, read_err := os.read_entire_file(source, allocator); read_err == nil {
				_ = os.write_entire_file(target, data)
			}
		}
	}
	env := make([dynamic]string, allocator)
	if inherited, err := os.environ(allocator); err == nil {
		for kv in inherited {
			if strings.has_prefix(kv, "GROK_HOME=") {
				continue
			}
			append(&env, kv)
		}
	}
	append(
		&env,
		strings.concatenate({"GROK_HOME=", home}, allocator),
		"GROK_MEMORY=0",
		"GROK_DISABLE_AUTOUPDATER=1",
		"GROK_CLAUDE_HOOKS_ENABLED=0",
		"GROK_CLAUDE_RULES_ENABLED=0",
		"GROK_CLAUDE_AGENTS_ENABLED=0",
		"GROK_CLAUDE_SKILLS_ENABLED=0",
		"GROK_CLAUDE_MCPS_ENABLED=0",
	)
	return env[:]
}

// grok_home is where grok keeps its credential: GROK_HOME, else .grok in
// the user's home.
grok_home :: proc(allocator := context.temp_allocator) -> string {
	if h := os.get_env("GROK_HOME", allocator); h != "" {
		return h
	}
	home := os.get_env("HOME", allocator)
	if home == "" {
		home = os.get_env("USERPROFILE", allocator)
	}
	return path.join(home, ".grok", allocator = allocator)
}

// Grok_Envelope is the headless JSON object: text, stopReason, usage, and
// total_cost_usd. A failure is the same stream with type "error".
// read_grok covers both.
Grok_Envelope :: struct {
	type:        string `json:"type"`,
	message:     string `json:"message"`,
	text:        string `json:"text"`,
	structured:  json.Value `json:"structuredOutput"`,
	stop_reason: string `json:"stopReason"`,
	cost:        f64 `json:"total_cost_usd"`,
	usage:       struct {
		tokens_in:  int `json:"input_tokens"`,
		tokens_out: int `json:"output_tokens"`,
		cached:     int `json:"cache_read_input_tokens"`,
	} `json:"usage"`,
}

// read_grok takes the answer out of grok's JSON object. Cost is left at
// zero when the server did not stamp one; a missing cost is not a free ask.
read_grok :: proc(out: string, allocator := context.allocator) -> (Answer, string) {
	envelope: Grok_Envelope
	if json.unmarshal_string(out, &envelope, allocator = context.temp_allocator) != nil {
		return {}, "reading the answer: not the JSON envelope expected"
	}
	if envelope.type == "error" {
		why := envelope.message if envelope.message != "" else "grok reported an error"
		return {}, strings.clone(why, allocator)
	}
	// The schema result is authoritative; text may contain narration before it.
	if object, ok := envelope.structured.(json.Object); ok {
		encoded, marshal_err := json.marshal(object, allocator = context.temp_allocator)
		if marshal_err != nil {return {}, "reading the structured Grok answer"}
		envelope.text = string(encoded)
	}
	if strings.trim_space(envelope.text) == "" {
		why := envelope.stop_reason if envelope.stop_reason != "" else "answered nothing"
		return {}, strings.clone(why, allocator)
	}
	return Answer {
			text = strings.clone(envelope.text, allocator),
			tokens_in = envelope.usage.tokens_in,
			tokens_out = envelope.usage.tokens_out,
			cached = envelope.usage.cached,
			cost = envelope.cost,
		},
		""
}

// ask_codex asks the codex assistant on the path, in its non-interactive
// mode, with whatever credentials it already holds. It is held to a
// read-only sandbox in an empty directory, with the user's config, hooks
// and rules left unread, so that it can neither edit nor wander the tree:
// these jobs are given everything they may read. Codex 0.163.0 has no
// system prompt flag among its exec options, so the system prompt leads the
// question. The answer is read from the last-message file, and the events
// on stdout carry the failure and the cost.
ask_codex :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	dir, mk_err := path.temp_dir("review-codex-", context.temp_allocator)
	if mk_err != nil {
		return {}, "codex: could not make a working directory"
	}
	defer os.remove_all(dir)
	last := path.join(dir, "last", allocator = context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	append(
		&args,
		"codex",
		"exec",
		"--json",
		"--ephemeral",
		"--skip-git-repo-check",
		"--ignore-user-config",
		"--ignore-rules",
		"--sandbox",
		"read-only",
		"--cd",
		dir,
		"--output-last-message",
		last,
	)
	if p.model != "" {
		append(&args, "--model", p.model)
	}
	append(&args, "-")
	out, err := shell(
		args[:],
		strings.concatenate({system, "\n\n", user}, context.temp_allocator),
		context.temp_allocator,
	)
	// A failed run is told by shell as its exit and the head of the stream,
	// which held the error event when the usage limit was hit.
	events := out
	if err != "" {
		events = err[max(strings.index_byte(err, '{'), 0):]
	}
	text, _ := os.read_entire_file(last, context.temp_allocator)
	return read_codex(events, string(text), allocator, err)
}

// Codex_Event is one line of codex's event stream: the failure of a turn,
// and the usage of a turn that finished.
Codex_Event :: struct {
	type:    string `json:"type"`,
	message: string `json:"message"`,
	error:   struct {
		message: string `json:"message"`,
	} `json:"error"`,
	usage:   struct {
		tokens_in:  int `json:"input_tokens"`,
		tokens_out: int `json:"output_tokens"`,
		cached:     int `json:"cached_input_tokens"`,
	} `json:"usage"`,
}

// read_codex takes the answer out of codex's last message, and the cost out
// of its event stream. A failed turn is told by the message the stream
// carries, in preference to the exit shell reports.
read_codex :: proc(
	events, text: string,
	allocator := context.allocator,
	failure := "",
) -> (
	Answer,
	string,
) {
	answer: Answer
	why := ""
	// Each event is read into an arena of its own, so that the failure cloned
	// out of one outlives the reading whichever allocator the caller holds.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return {}, strings.clone("codex: could not read the answer", allocator)
	}
	defer virtual.arena_destroy(&scratch)
	rest := events
	for raw in strings.split_lines_iterator(&rest) {
		event: Codex_Event
		if json.unmarshal_string(strings.trim_space(raw), &event, allocator = virtual.arena_allocator(&scratch)) != nil {
			continue
		}
		switch event.type {
		case "error":
			why = strings.clone(event.message, allocator)
		case "turn.failed":
			why = strings.clone(event.error.message, allocator)
		case "turn.completed":
			answer.tokens_in = event.usage.tokens_in
			answer.tokens_out = event.usage.tokens_out
			answer.cached = event.usage.cached
		}
	}
	if why != "" {
		return {}, why
	}
	if failure != "" {
		return {}, strings.clone(failure, allocator)
	}
	if strings.trim_space(text) == "" {
		return {}, strings.clone("answered nothing", allocator)
	}
	answer.text = strings.clone(text, allocator)
	return answer, ""
}

// ask_command asks whatever the environment names, with the prompt on its
// input, and reads the answer whole or out of the field named.
ask_command :: proc(
	p: Provider,
	system, user: string,
	allocator := context.allocator,
) -> (
	Answer,
	string,
) {
	if len(p.argv) == 0 {
		return {}, "REVIEW_COMMAND names no command"
	}
	out, err := shell(
		p.argv,
		strings.concatenate({system, "\n\n", user}, context.temp_allocator),
		allocator,
	)
	if err != "" {
		return {}, strings.clone(err, allocator)
	}
	if p.field == "" {
		return Answer{text = out}, ""
	}
	return Answer{text = field(out, p.field, allocator)}, ""
}

// shell works a command with the prompt on its input, which every
// assistant here accepts and which keeps a long prompt out of the
// argument list. A run past the ask timeout is a failed ask. env, where
// given, is the child's whole environment.
shell :: proc(
	argv: []string,
	prompt: string,
	allocator := context.allocator,
	env: []string = nil,
) -> (
	out: string,
	err: string,
) {
	r := sh.exec(
		argv,
		{stdin = prompt, env = env, timeout = time.Duration(ask_timeout_seconds()) * time.Second},
		allocator,
	)
	if r.err != nil {
		return "", fmt.aprintf("%s: %s", argv[0], os.error_string(r.err), allocator = allocator)
	}
	if r.timed_out {
		return "", fmt.aprintf(
			"%s: no answer within %d seconds",
			argv[0],
			ask_timeout_seconds(),
			allocator = allocator,
		)
	}
	if !r.ok {
		detail := strings.trim_space(r.stderr)
		if detail == "" {
			detail = strings.trim_space(r.stdout)
		}
		if len(detail) > 400 {
			detail = detail[:400]
		}
		return "", fmt.aprintf("%s: exit %d: %s", argv[0], r.code, detail, allocator = allocator)
	}
	return r.stdout, ""
}

// ask_timeout_seconds bounds one ask. A gateway that accepts a
// reachability ask and then stalls on a real one must not hold the review
// forever; REVIEW_ASK_TIMEOUT, in seconds, can widen it.
ask_timeout_seconds :: proc() -> int {
	if s := os.get_env("REVIEW_ASK_TIMEOUT", context.temp_allocator); s != "" {
		n := 0
		for i in 0 ..< len(s) {
			if s[i] < '0' || s[i] > '9' {
				n = 0
				break
			}
			n = n * 10 + int(s[i] - '0')
		}
		if n > 0 {
			return n
		}
	}
	return 300
}

// field pulls the answer out of a JSON envelope, by the name given. An
// answer that is not JSON at all is returned whole, since plenty of
// commands simply print what they were asked for.
field :: proc(out: string, name: string, allocator := context.allocator) -> string {
	value, err := json.parse_string(out, allocator = context.temp_allocator)
	if err != nil {
		return out
	}
	if envelope, is_object := value.(json.Object); is_object {
		if text, is_string := envelope[name].(json.String); is_string && text != "" {
			return strings.clone(string(text), allocator)
		}
	}
	return out
}

// first is the start of a string, with an ellipsis where it was cut.
first :: proc(s: string, n: int) -> string {
	trimmed := strings.trim_space(s)
	if len(trimmed) > n {
		return strings.concatenate({trimmed[:n], "…"}, context.temp_allocator)
	}
	return trimmed
}
