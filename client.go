package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/anthropics/anthropic-sdk-go"
)

// model is the one these jobs run on. Each is a narrow reading of a small
// packet, which is the cheapest tier's work, and it is the only tier where
// sampling can still be pinned.
const model = "claude-haiku-4-5"

// instruction is what every job is told, before its own criteria. It is kept
// identical across jobs so that the only thing that differs between them is
// the criteria and the subject.
const instruction = `You are reviewing one narrow aspect of a change to a repository.

Report only what the criteria below cover. Everything else is another reader's
job: say nothing about formatting, style, performance, or correctness unless a
criterion names it.

Rules for reporting:
- Every finding cites one rule id from the criteria, exactly as written.
- Severity is must-fix when the criterion is plainly broken, consider when it is
  a judgement call, note otherwise.
- A finding names the file and line it concerns where it has one.
- The fix is the concrete change to make, not a restatement of the problem.
- Reporting nothing is the right answer when the criteria are met. Do not
  manufacture findings to appear useful.
- You are shown only part of the change. Never infer what the rest contains.`

// rule matches a rule id where the criteria define one, which is the list a
// job is allowed to cite.
var rule = regexp.MustCompile("(?m)^- `([a-z0-9-]+)`")

// rules reads the ids a job may cite out of its own criteria.
func rules(criteria string) map[string]bool {
	out := map[string]bool{}
	for _, match := range rule.FindAllStringSubmatch(criteria, -1) {
		out[match[1]] = true
	}
	return out
}

// schema is what a job must answer in. It is enforced rather than requested:
// strict validation means a malformed answer cannot arrive.
var schema = anthropic.ToolInputSchemaParam{
	Properties: map[string]any{
		"findings": map[string]any{
			"type": "array",
			"items": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"rule":     map[string]any{"type": "string", "description": "the rule id from the criteria"},
					"severity": map[string]any{"type": "string", "enum": []string{"must-fix", "consider", "note"}},
					"file":     map[string]any{"type": "string"},
					"line":     map[string]any{"type": "integer"},
					"symbol":   map[string]any{"type": "string"},
					"message":  map[string]any{"type": "string", "description": "one sentence stating the finding"},
					"fix":      map[string]any{"type": "string", "description": "the concrete change to make"},
				},
				"required":             []string{"rule", "severity", "message", "fix", "file", "line", "symbol"},
				"additionalProperties": false,
			},
		},
	},
	Required: []string{"findings"},
}

// Reviewer runs jobs against a change.
type Reviewer struct {
	Client  anthropic.Client
	Verbose bool
}

// Run works every job that has something to read, at once. One job failing
// does not stop the others: a review that reports four of five readings is
// worth more than one that reports none.
func (r Reviewer) Run(ctx context.Context, change *Change, jobs []Job) ([]Finding, []error) {
	type result struct {
		findings []Finding
		err      error
	}
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		all     []Finding
		errored []error
	)
	for _, job := range jobs {
		subject := job.Subject(change)
		if strings.TrimSpace(subject) == "" {
			if r.Verbose {
				fmt.Printf("  %-12s nothing to read\n", job.Name)
			}
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			findings, err := r.ask(ctx, job, subject)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errored = append(errored, fmt.Errorf("%s: %w", job.Name, err))
				return
			}
			all = append(all, findings...)
		}()
	}
	wg.Wait()
	return all, errored
}

// ask puts one job's question. The criteria go in the system prompt where they
// can be cached across jobs and runs; the subject goes last, where it cannot
// disturb that prefix.
func (r Reviewer) ask(ctx context.Context, job Job, subject string) ([]Finding, error) {
	tool := anthropic.ToolParam{
		Name:        "report_findings",
		Description: anthropic.String("Report what this reading found, or an empty list."),
		InputSchema: schema,
		Strict:      anthropic.Bool(true),
	}
	resp, err := r.Client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     model,
		MaxTokens: 4096,
		// Pinned, because a loop between two models cannot converge if one of
		// them answers differently each time it is asked.
		Temperature: anthropic.Float(0),
		System: []anthropic.TextBlockParam{{
			Text:         instruction + "\n\n" + job.Criteria,
			CacheControl: anthropic.NewCacheControlEphemeralParam(),
		}},
		Tools: []anthropic.ToolUnionParam{{OfTool: &tool}},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(subject)),
		},
	})
	if err != nil {
		return nil, err
	}
	if r.Verbose {
		fmt.Printf("  %-12s %d in, %d out, %d cached\n",
			job.Name, resp.Usage.InputTokens, resp.Usage.OutputTokens, resp.Usage.CacheReadInputTokens)
	}
	allowed := rules(job.Criteria)
	var out []Finding
	for _, block := range resp.Content {
		use, ok := block.AsAny().(anthropic.ToolUseBlock)
		if !ok {
			continue
		}
		answer, err := decode(use.JSON.Input.Raw())
		if err != nil {
			return nil, err
		}
		out = append(out, answer.findings(job.Name, allowed)...)
	}
	return out, nil
}
