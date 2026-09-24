package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

// instruction is what every job is told, before its own criteria. It is kept
// identical across jobs and providers, so the only thing that differs between
// two readings is the criteria and the subject.
const instruction = `You are reviewing one narrow aspect of a change to a repository.

Report only what the criteria below cover. Everything else is another reader's
job: say nothing about formatting, style, performance, or correctness unless a
criterion names it.

Rules for reporting:
- Every finding cites one rule id from the criteria, exactly as written. A
  finding citing anything else is discarded.
- Severity is must-fix when the criterion is plainly broken, consider when it
  is a judgement call, note otherwise.
- A finding names the file and line it concerns where it has one.
- The fix is the concrete change to make, not a restatement of the problem.
- Reporting nothing is the right answer when the criteria are met. Do not
  manufacture findings to appear useful.
- You are shown only part of the change. Never infer what the rest contains.

Answer with one JSON object and nothing else. No preamble, no explanation, no
code fence:

{"findings":[{"rule":"","severity":"must-fix|consider|note","file":"","line":0,"symbol":"","message":"","fix":""}]}

Report no findings as {"findings":[]}.`

// verifyInstruction is what the second reading is told. It sees what the
// first one saw — the same criteria, the same part of the change — and
// nothing the first one concluded beyond the findings themselves, so that a
// verdict is a reading of the evidence rather than an agreement with a
// colleague.
const verifyInstruction = `You are checking findings another reviewer made against one narrow aspect of a change.

You are shown the criteria that reader judged against, the same part of the
change it read, and the findings it reported. For each finding, decide
whether it holds: the code it points at must meet the fault its rule
describes, judged from the evidence in front of you.

- Judge every finding, by its number. Report no verdicts but those.
- holds is false for a finding you would not report yourself from this
  evidence; say why in reason, in one sentence.
- A finding that holds but overstates its case does not hold as written.

Answer with one JSON object and nothing else. No preamble, no explanation, no
code fence:

{"verdicts":[{"index":0,"holds":true,"reason":""}]}`

// verdictsAgain is what the second reading is told when it answered in
// prose, in the shape of the retry the findings get.
const verdictsAgain = `Your previous answer was not a JSON object, so nothing was read from it.
Answer again, with one verdict per finding, as one JSON object and nothing else.`

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

// Retracted is a finding the verification pass did not let stand, and the
// reason. It is reported rather than dropped, so that a reading that retracts
// half of what it found says so instead of looking tidy.
type Retracted struct {
	Finding Finding `json:"finding"`
	Reason  string  `json:"reason"`
}

// RunResult is what a set of readings produced. The parts beyond the
// findings are what a program reading the JSON needs to trust an empty
// list: which jobs failed, which had nothing to read, and what the asking
// cost. An empty findings list against a run where every job failed is not
// a pass, and the result says which.
type RunResult struct {
	Findings  []Finding
	Failures  []error
	Retracted []Retracted
	Skipped   []string
	In        int
	Out       int
	Cached    int
	Replayed  int
	Cost      float64
}

// Reviewer runs jobs against a change, through whichever provider answers.
// Verify puts each job's findings back to the provider once, against the
// same evidence; the ones a second reading does not let stand are retracted
// rather than reported. Cache records what each ask cost and answered, so
// that a re-run of an unchanged part of the change replays instead of
// asking.
type Reviewer struct {
	Provider Provider
	Verify   bool
	Verbose  bool
	Cache    *AnswerCache
}

// Run works every job that has something to read, at once. One job failing
// does not stop the others: four readings out of five is worth more than none.
// REVIEW_SERIAL asks them one at a time instead, for providers that cannot
// take concurrent reads — the local maple gateway, which was observed to
// answer the biggest ask empty four runs in a row under parallelism and to
// answer the same ask fine on its own.
func (r Reviewer) Run(ctx context.Context, change *Change, jobs []Job) RunResult {
	var (
		mu     sync.Mutex
		result RunResult
	)
	record := func(job Job, findings []Finding, answer Answer, err error) {
		mu.Lock()
		defer mu.Unlock()
		result.In += answer.In
		result.Out += answer.Out
		result.Cached += answer.Cached
		result.Cost += answer.Cost
		if answer.Replayed {
			result.Replayed++
		}
		if err != nil {
			result.Failures = append(result.Failures, fmt.Errorf("%s: %w", job.Name, err))
			return
		}
		result.Findings = append(result.Findings, findings...)
	}
	// Every job's parts are cut once, and the same cut serves the second
	// reading, so a verdict is asked against exactly what the finding was
	// read from.
	cuts := map[string][]*Change{}
	for _, job := range jobs {
		cuts[job.Name] = parts(job, change)
	}
	read := func(job Job) {
		subject := job.Subject(change)
		if strings.TrimSpace(subject) == "" {
			mu.Lock()
			result.Skipped = append(result.Skipped, job.Name)
			mu.Unlock()
			if r.Verbose {
				fmt.Printf("  %-12s nothing to read\n", job.Name)
			}
			return
		}
		pieces := cuts[job.Name]
		if r.Verbose && len(pieces) > 1 {
			fmt.Printf("  %-12s asked in %d parts\n", job.Name, len(pieces))
		}
		for i, piece := range pieces {
			askCtx, cancel := askContext(ctx)
			findings, answer, err := r.ask(askCtx, job, job.Subject(piece))
			cancel()
			for j := range findings {
				findings[j].part = i
			}
			record(job, findings, answer, err)
		}
	}
	if os.Getenv("REVIEW_SERIAL") != "" {
		for _, job := range jobs {
			read(job)
		}
	} else {
		var wg sync.WaitGroup
		for _, job := range jobs {
			wg.Add(1)
			go func(job Job) {
				defer wg.Done()
				read(job)
			}(job)
		}
		wg.Wait()
	}
	// The skipped jobs are named in the jobs' own order, whichever
	// goroutine said so first, so the report reads the same on every run.
	order := map[string]int{}
	for i, job := range jobs {
		order[job.Name] = i
	}
	slices.SortFunc(result.Skipped, func(a, b string) int { return order[a] - order[b] })
	if r.Verify {
		r.verify(ctx, cuts, jobs, &result)
	}
	return result
}

// verifyGroup is one job's findings from one part of its subject, for the
// pass that checks them.
type verifyGroup struct {
	job     Job
	part    int
	indexes []int
}

// verify puts each job's findings back to the provider once, against the
// same evidence the first reading had, and keeps only the ones it also
// reports. A reading that misread the shortlist — the measured way a small
// model reports the first duplicate it finds — answers differently when the
// question is whether each finding holds. A verdict that cannot be asked
// fails open: the findings stand, marked unverified, and the failure joins
// the others.
func (r Reviewer) verify(ctx context.Context, cuts map[string][]*Change, jobs []Job, result *RunResult) {
	var groups []verifyGroup
	for _, job := range jobs {
		for part := range cuts[job.Name] {
			var indexes []int
			for i, f := range result.Findings {
				// A note is never gated on, so a second reading of it
				// buys nothing; it stands unverified, and the report
				// says so.
				if f.Job == job.Name && f.part == part && f.Severity != Note {
					indexes = append(indexes, i)
				}
			}
			if len(indexes) > 0 {
				groups = append(groups, verifyGroup{job: job, part: part, indexes: indexes})
			}
		}
	}
	if len(groups) == 0 {
		return
	}
	var (
		mu   sync.Mutex
		wg   sync.WaitGroup
		drop = map[int]bool{}
	)
	apply := func(group verifyGroup) {
		subject := group.job.Subject(cuts[group.job.Name][group.part])
		askCtx, cancel := askContext(ctx)
		held, answer, err := r.verdicts(askCtx, group.job, subject, result.Findings, group.indexes)
		cancel()
		mu.Lock()
		defer mu.Unlock()
		result.In += answer.In
		result.Out += answer.Out
		result.Cached += answer.Cached
		result.Cost += answer.Cost
		if answer.Replayed {
			result.Replayed++
		}
		if err != nil {
			result.Failures = append(result.Failures, fmt.Errorf("verify/%s: %w", group.job.Name, err))
			for _, i := range group.indexes {
				result.Findings[i].Verified = false
			}
			return
		}
		for position, i := range group.indexes {
			if v, judged := held[position]; judged && !v.Holds {
				result.Retracted = append(result.Retracted, Retracted{
					Finding: result.Findings[i],
					Reason:  v.Reason,
				})
				drop[i] = true
				continue
			}
			// A finding the verdict list omits stands rather than
			// falls: a strict pass would let one dropped number
			// retract everything the reading found.
			result.Findings[i].Verified = true
		}
	}
	defer func() {
		// A retracted finding is out of the findings: it is reported as a
		// retraction, with its reason, not twice over.
		if len(drop) == 0 {
			return
		}
		survivors := make([]Finding, 0, len(result.Findings))
		for i, f := range result.Findings {
			if !drop[i] {
				survivors = append(survivors, f)
			}
		}
		result.Findings = survivors
	}()
	if os.Getenv("REVIEW_SERIAL") != "" {
		for _, group := range groups {
			apply(group)
		}
		return
	}
	for _, group := range groups {
		wg.Add(1)
		go func(group verifyGroup) {
			defer wg.Done()
			apply(group)
		}(group)
	}
	wg.Wait()
}

// again is what a job is told when it answered in prose. Only the api
// provider can be held to a schema; the rest describe their findings instead
// often enough that losing the whole reading to it is the worse outcome.
const again = `Your previous answer was not a JSON object, so nothing was read from it.
Answer again, with the findings you already made, as one JSON object and nothing else.`

// askTimeout bounds one job's ask. The probe that picks a provider is
// bounded, and a job should be too: a gateway that accepts a reachability
// ask and then stalls on a real one must not hold the review forever. A
// timed-out job is a failed job, so the rest of the readings and the
// deterministic checks still report. Measured serial readings through the
// maple gateway run about 80 seconds at the largest; this is four times
// that, and REVIEW_ASK_TIMEOUT can widen it.
const askTimeout = 5 * time.Minute

func askTimeoutDuration() time.Duration {
	if s := os.Getenv("REVIEW_ASK_TIMEOUT"); s != "" {
		if d, err := time.ParseDuration(s); err == nil && d > 0 {
			return d
		}
	}
	return askTimeout
}

// askContext is one ask's deadline, counted from the ask's start.
func askContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, askTimeoutDuration())
}

// ask puts one job's question. The criteria are the system prompt, where a
// provider that caches anything will cache them; the subject goes last. The
// retry ask below gets its own deadline: a second chance is not bound by
// the first's remaining time.
func (r Reviewer) ask(ctx context.Context, job Job, subject string) ([]Finding, Answer, error) {
	system := instruction + "\n\n" + job.Criteria
	answer, err := r.answer(ctx, system, subject, r.Provider.Ask, readableFindings)
	if err != nil {
		return nil, Answer{}, err
	}
	r.spent(job, answer)
	raw, err := object(answer.Text)
	if err != nil {
		prose := first(answer.Text, 200)
		answer, err = r.answer(ctx, system, subject+"\n\n"+again, r.Provider.Ask, readableFindings)
		if err != nil {
			return nil, Answer{}, err
		}
		r.spent(job, answer)
		if raw, err = object(answer.Text); err != nil {
			return nil, answer, fmt.Errorf("%w, twice: %s", err, prose)
		}
	}
	reported, err := decode(raw)
	if err != nil {
		return nil, answer, err
	}
	return reported.findings(job.Name, rules(job.Criteria)), answer, nil
}

// answer asks through the cache: the same question asked of the same
// provider is replayed rather than asked, which is what makes a re-run
// cheap where nothing it judges changed. Only an answer the caller can read
// is recorded: a model that spent its whole budget and said nothing would
// otherwise be replayed, and the job would fail the same way on every run
// without ever asking again.
func (r Reviewer) answer(ctx context.Context, system, user string, ask func(context.Context, string, string) (Answer, error), readable func(string) bool) (Answer, error) {
	if r.Cache != nil {
		if answer, ok := r.Cache.get(r.Provider.Name(), system, user); ok {
			if r.Verbose {
				fmt.Printf("  %-12s replayed\n", r.Provider.Name())
			}
			return answer, nil
		}
	}
	answer, err := ask(ctx, system, user)
	if err == nil && r.Cache != nil && readable(answer.Text) {
		r.Cache.put(r.Provider.Name(), system, user, answer)
	}
	return answer, err
}

// readableFindings is whether an answer holds a findings object.
func readableFindings(text string) bool {
	raw, err := object(text)
	if err != nil {
		return false
	}
	_, err = decode(raw)
	return err == nil
}

// readableVerdicts is whether an answer holds a verdicts object.
func readableVerdicts(text string) bool {
	raw, err := object(text)
	if err != nil {
		return false
	}
	_, err = decodeVerdicts(raw)
	return err == nil
}

func (r Reviewer) spent(job Job, answer Answer) {
	if !r.Verbose {
		return
	}
	if answer.Replayed {
		fmt.Printf("  %-12s replayed\n", job.Name)
		return
	}
	fmt.Printf("  %-12s %d in, %d out, %d cached, $%.4f\n",
		job.Name, answer.In, answer.Out, answer.Cached, answer.Cost)
}

// verdict is what the second reading says about one finding.
type verdict struct {
	Holds  bool
	Reason string
}

// verdicts puts one job's findings back to the provider, against the same
// evidence the first reading had. Verdicts are keyed by position in the
// listing; a position the answer omits stands rather than falls.
func (r Reviewer) verdicts(ctx context.Context, job Job, subject string, findings []Finding, indexes []int) (map[int]verdict, Answer, error) {
	system := verifyInstruction + "\n\n" + job.Criteria
	var listed strings.Builder
	for position, i := range indexes {
		f := findings[i]
		where := ""
		if f.File != "" {
			where = fmt.Sprintf(" at %s:%d", f.File, f.Line)
		}
		fmt.Fprintf(&listed, "%d. [%s] %s%s: %s\n   fix: %s\n",
			position, f.Rule, f.Severity, where, f.Message, f.Fix)
	}
	user := subject + "\n\nThe findings reported against it:\n\n" + listed.String()
	answer, err := r.answer(ctx, system, user, verdictAsk(r.Provider), readableVerdicts)
	if err != nil {
		return nil, answer, err
	}
	r.spent(job, answer)
	raised, err := object(answer.Text)
	if err != nil {
		prose := first(answer.Text, 200)
		answer, err = r.answer(ctx, system, user+"\n\n"+verdictsAgain, verdictAsk(r.Provider), readableVerdicts)
		if err != nil {
			return nil, answer, err
		}
		r.spent(job, answer)
		if raised, err = object(answer.Text); err != nil {
			return nil, answer, fmt.Errorf("%w, twice: %s", err, prose)
		}
	}
	read, err := decodeVerdicts(raised)
	if err != nil {
		return nil, answer, err
	}
	held := map[int]verdict{}
	for _, v := range read.Verdicts {
		if v.Index >= 0 && v.Index < len(indexes) {
			held[v.Index] = verdict{Holds: v.Holds, Reason: v.Reason}
		}
	}
	return held, answer, nil
}

// spokenVerdicts is the shape the second reading answers in.
type spokenVerdicts struct {
	Verdicts []struct {
		Index  int    `json:"index"`
		Holds  bool   `json:"holds"`
		Reason string `json:"reason"`
	} `json:"verdicts"`
}

func decodeVerdicts(raw string) (spokenVerdicts, error) {
	var read spokenVerdicts
	if err := json.Unmarshal([]byte(raw), &read); err != nil {
		return spokenVerdicts{}, fmt.Errorf("the verdicts are not the shape asked for: %w", err)
	}
	return read, nil
}

// verdictAsk adapts whichever way a provider can be asked for verdicts —
// enforced as a tool where it can be, described in the prompt where it
// cannot — to one ask.
func verdictAsk(provider Provider) func(context.Context, string, string) (Answer, error) {
	if v, ok := provider.(Verdicts); ok {
		return v.AskVerdict
	}
	return provider.Ask
}

func first(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// API asks the console API directly. It is the one provider that can enforce
// the answer's shape rather than request it, so a malformed answer is
// impossible here rather than merely unlikely.
type API struct{ Model string }

func (a API) Name() string { return "api/" + a.Model }

// schema is the shape a finding takes, enforced where a provider can enforce
// it and described in the prompt where it cannot.
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

// verdictSchema is the shape the second reading answers in, held to the
// same strictness where the provider allows it.
var verdictSchema = anthropic.ToolInputSchemaParam{
	Properties: map[string]any{
		"verdicts": map[string]any{
			"type": "array",
			"items": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"index":  map[string]any{"type": "integer", "description": "the number of the finding, as it was listed"},
					"holds":  map[string]any{"type": "boolean", "description": "whether the finding stands against the criteria"},
					"reason": map[string]any{"type": "string", "description": "why it holds or falls, one sentence"},
				},
				"required":             []string{"index", "holds", "reason"},
				"additionalProperties": false,
			},
		},
	},
	Required: []string{"verdicts"},
}

func (a API) Ask(ctx context.Context, system, user string) (Answer, error) {
	return a.call(ctx, system, user, "report_findings", "Report what this reading found, or an empty list.", schema)
}

// Verdicts is what a provider offers when it can hold the second reading to
// its shape as well.
type Verdicts interface {
	AskVerdict(ctx context.Context, system, user string) (Answer, error)
}

func (a API) AskVerdict(ctx context.Context, system, user string) (Answer, error) {
	return a.call(ctx, system, user, "report_verdicts", "Report whether each finding holds.", verdictSchema)
}

// call asks one question with one strict tool, which is the whole of both
// asks: the shape differs, the conversation does not.
func (a API) call(ctx context.Context, system, user, name, description string, shape anthropic.ToolInputSchemaParam) (Answer, error) {
	tool := anthropic.ToolParam{
		Name:        name,
		Description: anthropic.String(description),
		InputSchema: shape,
		Strict:      anthropic.Bool(true),
	}
	client := anthropic.NewClient()
	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     a.Model,
		MaxTokens: 4096,
		// Pinned, because a loop between two models cannot converge if one of
		// them answers differently each time it is asked.
		Temperature: anthropic.Float(0),
		System: []anthropic.TextBlockParam{{
			Text:         system,
			CacheControl: anthropic.NewCacheControlEphemeralParam(),
		}},
		Tools:    []anthropic.ToolUnionParam{{OfTool: &tool}},
		Messages: []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(user))},
	})
	if err != nil {
		return Answer{}, err
	}
	answer := Answer{
		In: int(resp.Usage.InputTokens), Out: int(resp.Usage.OutputTokens),
		Cached: int(resp.Usage.CacheReadInputTokens),
	}
	for _, block := range resp.Content {
		if use, ok := block.AsAny().(anthropic.ToolUseBlock); ok {
			answer.Text = use.JSON.Input.Raw()
			return answer, nil
		}
	}
	return answer, fmt.Errorf("the model answered without reporting")
}
