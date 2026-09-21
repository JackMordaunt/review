package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Provider answers a question. What answers it is not this tool's business:
// a console API, a coding assistant on the path, or anything else that takes
// a prompt and returns text.
type Provider interface {
	// Name is how it is asked for.
	Name() string
	// Ask puts one question and returns what came back, as text. Findings are
	// read out of that text by the caller, so every provider answers the same
	// way whether or not it can enforce a schema.
	Ask(ctx context.Context, system, user string) (Answer, error)
}

// Answer is what a provider returned, with whatever it could say about the
// cost. A provider that reports no usage leaves the counts at zero rather
// than inventing them. Replayed marks an answer the cache remembered rather
// than asked for: it cost nothing this run, so its counts stay at zero.
type Answer struct {
	Text     string
	In       int
	Out      int
	Cached   int
	Cost     float64
	Replayed bool
}

// Providers returns the ones built in, by name.
//
// The default model is the middle one rather than the smallest. Measured
// against the eval set, the smallest reads the shortlist and reports the
// first duplicate it finds rather than all of them, which is the one thing
// this tool is for.
func Providers() map[string]func(model string) Provider {
	return map[string]func(string) Provider{
		"claude": func(model string) Provider { return ClaudeCode{Model: orElse(model, "sonnet")} },
		"pi":     func(model string) Provider { return Pi{Model: model, Upstream: os.Getenv("REVIEW_PI_PROVIDER")} },
		"api":    func(model string) Provider { return API{Model: orElse(model, "claude-sonnet-5")} },
		"command": func(model string) Provider {
			return Command{Argv: strings.Fields(os.Getenv("REVIEW_COMMAND")), Field: os.Getenv("REVIEW_COMMAND_FIELD")}
		},
	}
}

func orElse(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

// ClaudeCode asks the coding assistant on the path, in its non-interactive
// mode. It uses whatever credentials that assistant already holds, which is
// why it works where no API key is set.
type ClaudeCode struct{ Model string }

// Name carries the model, so that two asks through differently pointed
// providers are never confused — the answer cache keys on it.
func (c ClaudeCode) Name() string { return "claude/" + c.Model }

func (c ClaudeCode) Ask(ctx context.Context, system, user string) (Answer, error) {
	// The tools are refused rather than left to judgement: these jobs are
	// given everything they may read, and a reader that goes looking for more
	// is answering a different question from the one asked.
	out, err := shell(ctx, "claude",
		[]string{
			"-p", "--model", c.Model, "--output-format", "json",
			"--disallowedTools", "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit",
			"--append-system-prompt", system,
		}, user)
	if err != nil {
		return Answer{}, err
	}
	var envelope struct {
		Result  string  `json:"result"`
		IsError bool    `json:"is_error"`
		Cost    float64 `json:"total_cost_usd"`
		Usage   struct {
			In     int `json:"input_tokens"`
			Out    int `json:"output_tokens"`
			Cached int `json:"cache_read_input_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(out, &envelope); err != nil {
		return Answer{}, fmt.Errorf("reading the answer: %w", err)
	}
	if envelope.IsError {
		return Answer{}, fmt.Errorf("%s", strings.TrimSpace(envelope.Result))
	}
	return Answer{
		Text: envelope.Result, In: envelope.Usage.In, Out: envelope.Usage.Out,
		Cached: envelope.Usage.Cached, Cost: envelope.Cost,
	}, nil
}

// Pi asks the assistant of the same name, which speaks to several providers
// of its own. The upstream provider is named through the environment rather
// than here, since which one is reachable is a property of the machine. Its
// answer arrives as a stream of events, not as one envelope.
type Pi struct{ Model, Upstream string }

// Name carries the upstream and the model, for the same reason.
func (p Pi) Name() string {
	name := "pi"
	if p.Upstream != "" {
		name += "/" + p.Upstream
	}
	if p.Model != "" {
		name += "/" + p.Model
	}
	return name
}

func (p Pi) Ask(ctx context.Context, system, user string) (Answer, error) {
	// The tools are refused for the same reason as the other assistant: a
	// reader that goes looking for more is answering a different question.
	args := []string{"-p", "--mode", "json", "--no-session", "--no-tools", "--system-prompt", system}
	if p.Upstream != "" {
		args = append(args, "--provider", p.Upstream)
	}
	if p.Model != "" {
		args = append(args, "--model", p.Model)
	}
	out, err := shell(ctx, "pi", args, user)
	if err != nil {
		return Answer{}, err
	}
	return spoken(out)
}

// spoken reads pi's answer out of its event stream, which is one JSON object
// per line rather than one envelope. The last assistant message is the
// answer; everything before it is the working.
func spoken(out []byte) (Answer, error) {
	var (
		answer Answer
		said   bool
		prose  []string
	)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event struct {
			Type    string `json:"type"`
			Message struct {
				Role    string `json:"role"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
				Usage struct {
					Input     int `json:"input"`
					Output    int `json:"output"`
					CacheRead int `json:"cacheRead"`
					Cost      struct {
						Total float64 `json:"total"`
					} `json:"cost"`
				} `json:"usage"`
				StopReason   string `json:"stopReason"`
				ErrorMessage string `json:"errorMessage"`
			} `json:"message"`
		}
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			// Whatever pi says outside the stream is the only clue to a
			// refusal, so it is kept for the error.
			prose = append(prose, line)
			continue
		}
		if event.Type != "message_end" || event.Message.Role != "assistant" {
			continue
		}
		if event.Message.StopReason == "error" {
			return Answer{}, fmt.Errorf("%s", orElse(event.Message.ErrorMessage, "the model stopped with an error"))
		}
		var text strings.Builder
		for _, block := range event.Message.Content {
			if block.Type == "text" {
				text.WriteString(block.Text)
			}
		}
		usage := event.Message.Usage
		answer = Answer{
			Text: text.String(), In: usage.Input, Out: usage.Output,
			Cached: usage.CacheRead, Cost: usage.Cost.Total,
		}
		said = true
	}
	if !said {
		return Answer{}, fmt.Errorf("%s", orElse(first(strings.Join(prose, " "), 200), "no assistant message in the answer"))
	}
	return answer, nil
}

// Command asks whatever the environment names, for a provider this tool has
// never heard of. REVIEW_COMMAND is the command line; REVIEW_COMMAND_FIELD is
// the JSON field its answer arrives in, where it answers in JSON at all.
type Command struct {
	Argv  []string
	Field string
}

// Name carries the command line, because two commands under the same name
// are different providers as far as the cache is concerned.
func (c Command) Name() string {
	if len(c.Argv) == 0 {
		return "command"
	}
	return "command: " + strings.Join(c.Argv, " ")
}

func (c Command) Ask(ctx context.Context, system, user string) (Answer, error) {
	if len(c.Argv) == 0 {
		return Answer{}, fmt.Errorf("REVIEW_COMMAND names no command")
	}
	out, err := shell(ctx, c.Argv[0], c.Argv[1:], system+"\n\n"+user)
	if err != nil {
		return Answer{}, err
	}
	if c.Field == "" {
		return Answer{Text: string(out)}, nil
	}
	return Answer{Text: field(out, c.Field)}, nil
}

// shell works a command with the prompt on its input, which every assistant
// here accepts and which keeps a long prompt out of the argument list.
func shell(ctx context.Context, name string, args []string, prompt string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(prompt)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = strings.TrimSpace(string(out))
		}
		if len(detail) > 400 {
			detail = detail[:400]
		}
		return nil, fmt.Errorf("%s: %w: %s", name, err, detail)
	}
	return out, nil
}

// field pulls the answer out of a JSON envelope, taking the first of the
// names that holds a string. An answer that is not JSON at all is returned
// whole, since plenty of commands simply print what they were asked for.
func field(out []byte, names ...string) string {
	var envelope map[string]any
	if err := json.Unmarshal(out, &envelope); err != nil {
		return string(out)
	}
	for _, name := range names {
		if text, ok := envelope[name].(string); ok && text != "" {
			return text
		}
	}
	return string(out)
}

// object finds the JSON object in an answer. Only a provider that can enforce
// a schema returns bare JSON; the rest wrap it in whatever they were minded
// to say, so the object is taken from within the text.
func object(text string) (string, error) {
	start := strings.Index(text, "{")
	end := strings.LastIndex(text, "}")
	if start < 0 || end < start {
		return "", fmt.Errorf("no findings object in the answer")
	}
	return text[start : end+1], nil
}
