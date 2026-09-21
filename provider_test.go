package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestObject(t *testing.T) {
	for _, test := range []struct {
		name   string
		answer string
		want   string
	}{{
		name:   "bare json is returned whole",
		answer: `{"findings":[]}`,
		want:   `{"findings":[]}`,
	}, {
		name:   "a fenced answer gives up its object",
		answer: "Here is what I found:\n```json\n{\"findings\":[{\"rule\":\"cannot-fail\"}]}\n```\nHope that helps.",
		want:   `{"findings":[{"rule":"cannot-fail"}]}`,
	}, {
		name:   "prose on both sides is stripped",
		answer: "I reviewed it. {\"findings\":[]} Let me know.",
		want:   `{"findings":[]}`,
	}, {
		name:   "nested braces survive",
		answer: `prefix {"findings":[{"rule":"a"},{"rule":"b"}]} suffix`,
		want:   `{"findings":[{"rule":"a"},{"rule":"b"}]}`,
	}} {
		t.Run(test.name, func(t *testing.T) {
			got, err := object(test.answer)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Errorf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestObjectWithNothingToFind(t *testing.T) {
	for _, answer := range []string{"", "I could not answer that.", "}{"} {
		if _, err := object(answer); err == nil {
			t.Errorf("object(%q) should fail", answer)
		}
	}
}

func TestField(t *testing.T) {
	// The first name holding a string wins.
	got := field([]byte(`{"text":"","result":"answer","content":"other"}`), "result", "text", "content")
	if got != "answer" {
		t.Errorf("got %q", got)
	}
	// An empty value is passed over, which is what lets one set of names
	// serve several envelopes.
	got = field([]byte(`{"result":"","text":"answer"}`), "result", "text")
	if got != "answer" {
		t.Errorf("got %q", got)
	}
	// Plenty of commands simply print what they were asked for.
	if got := field([]byte("just text"), "result"); got != "just text" {
		t.Errorf("got %q", got)
	}
	// JSON that holds none of the names is returned whole rather than lost.
	raw := `{"other":"answer"}`
	if got := field([]byte(raw), "result"); got != raw {
		t.Errorf("got %q", got)
	}
}

func TestProvidersAreNamed(t *testing.T) {
	providers := Providers()
	if len(providers) == 0 {
		t.Fatal("Providers() returned no providers")
	}
	for name, build := range providers {
		// A name is the start of what the provider calls itself: the model
		// is carried as well, because the answer cache keys on the pair.
		if got := build("").Name(); !strings.HasPrefix(got, name) {
			t.Errorf("provider %q calls itself %q", name, got)
		}
	}
}

func TestNamesCarryTheModel(t *testing.T) {
	providers := Providers()
	if len(providers) == 0 {
		t.Fatal("Providers() returned no providers")
	}
	for name, build := range providers {
		got := build("probe-model").Name()
		// The command provider is named by its command line rather than its
		// model, which it does not take; its argv is the identity that two
		// commands under one name would collide on.
		if name == "command" {
			continue
		}
		// The model is carried after the provider's own name: a name that
		// echoed the model alone would not say which provider answered,
		// and two providers sharing a model would collide in the cache.
		if !strings.HasPrefix(got, name+"/") {
			t.Errorf("provider %q names itself %q", name, got)
		}
		if !strings.Contains(got, "probe-model") {
			t.Errorf("provider %q names itself %q without the model", name, got)
		}
	}
	argv := Command{Argv: []string{"my", "reviewer"}}.Name()
	if argv != "command: my reviewer" {
		t.Errorf("got %q", argv)
	}
}

func TestOrElse(t *testing.T) {
	if got := orElse("", "fallback"); got != "fallback" {
		t.Errorf("got %q", got)
	}
	if got := orElse("value", "fallback"); got != "value" {
		t.Errorf("got %q", got)
	}
}

// Command is the seam for a provider this tool has never heard of, so it is
// exercised with a command that is certainly on the path.
func TestCommandProvider(t *testing.T) {
	c := Command{Argv: []string{"sh", "-c", `cat > /dev/null; printf '{"findings":[]}'`}}
	answer, err := c.Ask(context.Background(), "system", "user")
	if err != nil {
		t.Fatal(err)
	}
	if answer.Text != `{"findings":[]}` {
		t.Errorf("got %q", answer.Text)
	}
}

// The prompt reaches the command on its input, which is what keeps a long
// prompt out of the argument list.
func TestCommandProviderIsGivenThePrompt(t *testing.T) {
	c := Command{Argv: []string{"cat"}}
	answer, err := c.Ask(context.Background(), "the criteria", "the change")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(answer.Text, "the criteria") || !strings.Contains(answer.Text, "the change") {
		t.Errorf("got %q", answer.Text)
	}
}

func TestCommandProviderReadsItsField(t *testing.T) {
	c := Command{
		Argv:  []string{"sh", "-c", `cat > /dev/null; printf '{"answer":"{\\"findings\\":[]}"}'`},
		Field: "answer",
	}
	answer, err := c.Ask(context.Background(), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if answer.Text != `{"findings":[]}` {
		t.Errorf("got %q", answer.Text)
	}
}

func TestCommandProviderWithoutACommand(t *testing.T) {
	if _, err := (Command{}).Ask(context.Background(), "", ""); err == nil {
		t.Error("a provider with no command should say so")
	}
}

// A failing command reports what it printed, since that is the only clue to
// why it failed.
func TestCommandProviderReportsFailure(t *testing.T) {
	c := Command{Argv: []string{"sh", "-c", "echo not logged in >&2; exit 1"}}
	_, err := c.Ask(context.Background(), "", "")
	if err == nil {
		t.Fatal("a command that exits non-zero should fail")
	}
	if !strings.Contains(err.Error(), "not logged in") {
		t.Errorf("the reason is missing from %q", err)
	}
}

func TestShellCancels(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := shell(ctx, "sh", []string{"-c", "sleep 10"}, ""); err == nil {
		t.Error("a cancelled context should stop the command")
	}
}

// standIn puts a command of the given name on the path, which answers with
// what it is given and records the arguments and input it was called with.
// The assistants themselves need credentials this machine does not have.
func standIn(t *testing.T, dir, name, answer string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	script := "#!/bin/sh\ncat > \"$0.stdin\"\nprintf '%s' \"$*\" > \"$0.args\"\n" + answer
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return path
}

// piStream is the shape pi's documented event stream takes: one JSON object
// per line, the last assistant message carrying the answer.
const piStream = `{"type":"session","version":3,"id":"01a0","timestamp":"2026-09-21T16:57:13.552Z","cwd":"/tmp"}
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"assistant","content":[]}}
{"type":"message_update","usage":{"input":0,"output":0},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"{"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"weighing it up"},{"type":"text","text":"{\"findings\":[]}"}],"usage":{"input":1200,"output":40,"cacheRead":900,"cacheWrite":0,"totalTokens":1240,"cost":{"input":0.001,"output":0.002,"cacheRead":0,"cacheWrite":0,"total":0.003}},"stopReason":"stop"}}
{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[]}
{"type":"agent_end","messages":[]}
`

func TestSpoken(t *testing.T) {
	answer, err := spoken([]byte(piStream))
	if err != nil {
		t.Fatal(err)
	}
	if answer.Text != `{"findings":[]}` {
		t.Errorf("got %q", answer.Text)
	}
	// Thinking is not the answer.
	if strings.Contains(answer.Text, "weighing") {
		t.Errorf("thinking leaked into the answer: %q", answer.Text)
	}
	if answer.In != 1200 || answer.Out != 40 || answer.Cached != 900 {
		t.Errorf("usage: got %+v", answer)
	}
	if answer.Cost != 0.003 {
		t.Errorf("cost: got %v, want the total", answer.Cost)
	}
}

// pi reports a refusal in the message it stopped on, which is the only place
// the reason appears.
func TestSpokenReportsAnError(t *testing.T) {
	stream := `{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"context length exceeded"}}`
	_, err := spoken([]byte(stream))
	if err == nil || !strings.Contains(err.Error(), "context length exceeded") {
		t.Errorf("got %v", err)
	}
}

// With no credentials pi says so outside the stream, so that is what the
// error has to carry.
func TestSpokenCarriesWhatWasSaidOutsideTheStream(t *testing.T) {
	out := `{"type":"session","version":3,"id":"01a0"}
No API key found for the selected model.
`
	_, err := spoken([]byte(out))
	if err == nil || !strings.Contains(err.Error(), "No API key found") {
		t.Errorf("got %v", err)
	}
}

func TestSpokenWithNothingAtAll(t *testing.T) {
	if _, err := spoken(nil); err == nil {
		t.Error("an empty answer should fail")
	}
}

// Pi.Ask is exercised against a stand-in on the path, since the assistant
// itself needs credentials this machine does not have.
func TestPiAsk(t *testing.T) {
	dir := t.TempDir()
	path := standIn(t, dir, "pi", "cat <<'STREAM'\n"+piStream+"STREAM\n")

	p := Pi{Model: "gpt-5", Upstream: "openai"}
	answer, err := p.Ask(context.Background(), "the criteria", "the change")
	if err != nil {
		t.Fatal(err)
	}
	if answer.Text != `{"findings":[]}` {
		t.Errorf("got %q", answer.Text)
	}
	args, err := os.ReadFile(path + ".args")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"--mode json", "--no-session", "--no-tools", "--system-prompt the criteria", "--provider openai", "--model gpt-5"} {
		if !strings.Contains(string(args), want) {
			t.Errorf("%q missing from the arguments: %s", want, args)
		}
	}
	// The prompt goes on the input, not the argument list.
	stdin, err := os.ReadFile(path + ".stdin")
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(stdin)) != "the change" {
		t.Errorf("got %q on the input", stdin)
	}
	if strings.Contains(string(args), "the change") {
		t.Errorf("the prompt reached the argument list: %s", args)
	}
}

// The tools that answer these jobs are refused rather than left to
// judgement, and the prompt goes on the input where a variadic flag cannot
// swallow it.
func TestClaudeCodeAsk(t *testing.T) {
	dir := t.TempDir()
	path := standIn(t, dir, "claude", "cat <<'ENVELOPE'\n"+
		`{"result":"{\"findings\":[]}","is_error":false,"total_cost_usd":0.05,`+
		`"usage":{"input_tokens":9,"output_tokens":40,"cache_read_input_tokens":800}}`+
		"\nENVELOPE\n")

	answer, err := ClaudeCode{Model: "sonnet"}.Ask(context.Background(), "the criteria", "the change")
	if err != nil {
		t.Fatal(err)
	}
	if answer.Text != `{"findings":[]}` || answer.Cost != 0.05 || answer.Cached != 800 {
		t.Errorf("got %+v", answer)
	}
	args, err := os.ReadFile(path + ".args")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(args), "--disallowedTools Bash,Read,") {
		t.Errorf("the tools are not refused: %s", args)
	}
	// --disallowedTools is variadic and swallows a positional prompt.
	if strings.Contains(string(args), "the change") {
		t.Errorf("the prompt reached the argument list: %s", args)
	}
	// --bare sets CLAUDE_CODE_SIMPLE=1 and restricts authentication to an
	// API key, which breaks a machine using the logged-in session.
	if strings.Contains(string(args), "--bare") {
		t.Errorf("--bare is back: %s", args)
	}
}

func TestClaudeCodeReportsAnError(t *testing.T) {
	dir := t.TempDir()
	standIn(t, dir, "claude", "cat <<'ENVELOPE'\n"+
		`{"result":"Not logged in","is_error":true}`+"\nENVELOPE\n")

	_, err := ClaudeCode{Model: "sonnet"}.Ask(context.Background(), "", "")
	if err == nil || !strings.Contains(err.Error(), "Not logged in") {
		t.Errorf("got %v", err)
	}
}

// The default is the middle model: the smallest reads the shortlist and
// reports the first duplicate rather than all of them.
func TestDefaultModels(t *testing.T) {
	if got := Providers()["claude"]("").(ClaudeCode).Model; got != "sonnet" {
		t.Errorf("claude defaults to %q", got)
	}
	if got := Providers()["api"]("").(API).Model; got != "claude-sonnet-5" {
		t.Errorf("api defaults to %q", got)
	}
	if got := Providers()["claude"]("haiku").(ClaudeCode).Model; got != "haiku" {
		t.Errorf("a named model is used, got %q", got)
	}
}
