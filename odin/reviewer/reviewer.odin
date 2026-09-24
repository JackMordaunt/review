/*
Package reviewer runs the jobs against a change, through whichever
provider answers. Each job's findings are put back to the provider once,
against the same evidence, and the ones a second reading does not let
stand are retracted rather than reported. The cache records what each ask
answered, so a re-run of an unchanged part of the change replays instead
of asking. What every job is told is the Go tool's, word for word, so the
two tools share one cache.
*/
package reviewer

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import "../cache"
import "../change"
import "../finding"
import "../job"
import "../provider"
import "../report"
import "../txt"

// instruction is what every job is told, before its own criteria. It is
// kept identical across jobs and providers, so the only thing that differs
// between two readings is the criteria and the subject.
instruction :: `You are reviewing one narrow aspect of a change to a repository.

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

// verify_instruction is what the second reading is told. It sees what
// the first one saw and nothing the first one concluded beyond the
// findings themselves, so that a verdict is a reading of the evidence
// rather than an agreement with a colleague.
verify_instruction :: `You are checking findings another reviewer made against one narrow aspect of a change.

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

// again is what a job is told when it answered in prose; verdicts_again
// the same for the second reading.
again :: `Your previous answer was not a JSON object, so nothing was read from it.
Answer again, with the findings you already made, as one JSON object and nothing else.`

verdicts_again :: `Your previous answer was not a JSON object, so nothing was read from it.
Answer again, with one verdict per finding, as one JSON object and nothing else.`

// Reviewer is how the jobs are asked: the provider, whether to verify,
// whether to narrate, and the cache to replay from.
Reviewer :: struct {
	provider: provider.Provider,
	name:     string,
	verify:   bool,
	verbose:  bool,
	cache:    ^cache.Cache,
}

// Result is what a set of readings produced. The parts beyond the
// findings are what a program reading the JSON needs to trust an empty
// list: which jobs failed, which had nothing to read, and what the
// asking cost.
Result :: struct {
	findings:   [dynamic]finding.Finding,
	failures:   [dynamic]string,
	retracted:  [dynamic]report.Retracted,
	skipped:    [dynamic]string,
	tokens_in:  int,
	tokens_out: int,
	cached:     int,
	replayed:   int,
	cost:       f64,
}

// Task is one job's reading, as a thread carries it.
@(private)
Task :: struct {
	r:      ^Reviewer,
	j:      job.Job,
	pieces: []^change.Change,
	result: ^Result,
	lock:   ^sync.Mutex,
}

// run works every job that has something to read, at once. One job
// failing does not stop the others: four readings out of five is worth
// more than none. REVIEW_SERIAL asks them one at a time instead, for
// providers that cannot take concurrent reads.
run :: proc(
	r: ^Reviewer,
	c: ^change.Change,
	jobs: []job.Job,
	serial := false,
	allocator := context.allocator,
) -> Result {
	context.allocator = allocator
	result := Result {
		findings  = make([dynamic]finding.Finding),
		failures  = make([dynamic]string),
		retracted = make([dynamic]report.Retracted),
		skipped   = make([dynamic]string),
	}
	lock: sync.Mutex
	// Every job's parts are cut once, and the same cut serves the second
	// reading, so a verdict is asked against exactly what the finding was
	// read from.
	tasks := make([]Task, len(jobs), context.temp_allocator)
	for j, i in jobs {
		tasks[i] = Task {
			r      = r,
			j      = j,
			pieces = job.parts(j, c, allocator),
			result = &result,
			lock   = &lock,
		}
	}
	one_at_a_time := serial || os.get_env("REVIEW_SERIAL", context.temp_allocator) != ""
	if one_at_a_time {
		for &t in tasks {
			read(&t)
		}
	} else {
		threads := make([dynamic]^thread.Thread, context.temp_allocator)
		for &t in tasks {
			ctx := runtime.default_context()
			ctx.allocator = allocator
			append(&threads, thread.create_and_start_with_poly_data(&t, read, ctx))
		}
		for th in threads {
			thread.join(th)
			thread.destroy(th)
		}
	}
	// The skipped jobs are named in the jobs' own order, whichever
	// thread said so first.
	ordered := make([dynamic]string, allocator)
	for j in jobs {
		for name in result.skipped {
			if name == j.name {
				append(&ordered, name)
			}
		}
	}
	result.skipped = ordered
	if r.verify {
		verify(r, tasks, &result, one_at_a_time, allocator)
	}
	return result
}

// read is one job's reading: nothing when there is nothing to read, else
// each part asked and recorded.
@(private)
read :: proc(t: ^Task) {
	subject := t.j.subject(t.pieces[0], context.temp_allocator)
	whole := len(t.pieces) == 1
	if whole && strings.trim_space(subject) == "" {
		sync.mutex_lock(t.lock)
		append(&t.result.skipped, strings.clone(t.j.name))
		sync.mutex_unlock(t.lock)
		if t.r.verbose {
			fmt.printfln("  %-12s nothing to read", t.j.name)
		}
		return
	}
	if t.r.verbose && len(t.pieces) > 1 {
		fmt.printfln("  %-12s asked in %d parts", t.j.name, len(t.pieces))
	}
	for piece, i in t.pieces {
		found, answer, err := ask(t.r, t.j, t.j.subject(piece, context.temp_allocator))
		for &f in found {
			f.part = i
		}
		record(t.result, t.lock, t.j.name, found, answer, err)
	}
}

// record keeps one ask's findings or failure, and what it cost.
@(private)
record :: proc(
	result: ^Result,
	lock: ^sync.Mutex,
	name: string,
	found: []finding.Finding,
	answer: provider.Answer,
	err: string,
) {
	sync.mutex_lock(lock)
	defer sync.mutex_unlock(lock)
	result.tokens_in += answer.tokens_in
	result.tokens_out += answer.tokens_out
	result.cached += answer.cached
	result.cost += answer.cost
	if answer.replayed {
		result.replayed += 1
	}
	if err != "" {
		append(&result.failures, fmt.aprintf("%s: %s", name, err))
		return
	}
	append(&result.findings, ..found)
}

// ask puts one job's question. The criteria are the system prompt, where
// a provider that caches anything will cache them; the subject goes last.
// An answer in prose is asked again once.
@(private)
ask :: proc(
	r: ^Reviewer,
	j: job.Job,
	subject: string,
) -> (
	found: []finding.Finding,
	answer: provider.Answer,
	err: string,
) {
	system := strings.concatenate({instruction, "\n\n", j.criteria}, context.temp_allocator)
	answer, err = answered(r, system, subject, false, job.readable)
	if err != "" {
		return nil, {}, err
	}
	spent(r, j.name, answer)
	raw, found_object := txt.object(answer.text)
	if !found_object {
		prose := provider.first(answer.text, 200)
		answer, err = answered(
			r,
			system,
			strings.concatenate({subject, "\n\n", again}, context.temp_allocator),
			false,
			job.readable,
		)
		if err != "" {
			return nil, {}, err
		}
		spent(r, j.name, answer)
		raw, found_object = txt.object(answer.text)
		if !found_object {
			return nil, answer, fmt.aprintf("no findings object in the answer, twice: %s", prose)
		}
	}
	decoded, ok := job.decode(raw, j.name, job.rules(j.criteria))
	if !ok {
		return nil, answer, "reading the answer: the findings are not the shape asked for"
	}
	return decoded, answer, ""
}

// answered asks through the cache: the same question asked of the same
// provider is replayed rather than asked. Only an answer the caller can
// read is recorded: a model that spent its whole budget and said nothing
// would otherwise be replayed on every run.
@(private)
answered :: proc(
	r: ^Reviewer,
	system, user: string,
	verdict: bool,
	readable: proc(text: string) -> bool,
) -> (
	provider.Answer,
	string,
) {
	if os.get_env("REVIEW_DEBUG_CACHE", context.temp_allocator) != "" {
		fmt.eprintfln(
			"cache key %s system=%d user=%d provider=%s",
			cache.key(r.name, system, user, context.temp_allocator)[:12],
			len(system),
			len(user),
			r.name,
		)
	}
	if hit, replayed := cache.get(r.cache, r.name, system, user); replayed {
		if r.verbose {
			fmt.printfln("  %-12s replayed", r.name)
		}
		return hit, ""
	}
	answer: provider.Answer
	err: string
	if verdict {
		answer, err = provider.ask_verdict(r.provider, system, user)
	} else {
		answer, err = provider.ask(r.provider, system, user)
	}
	if err == "" && readable(answer.text) {
		cache.put(r.cache, r.name, system, user, answer)
	}
	return answer, err
}

@(private)
spent :: proc(r: ^Reviewer, name: string, answer: provider.Answer) {
	if !r.verbose {
		return
	}
	if answer.replayed {
		fmt.printfln("  %-12s replayed", name)
		return
	}
	fmt.printfln(
		"  %-12s %d in, %d out, %d cached, $%.4f",
		name,
		answer.tokens_in,
		answer.tokens_out,
		answer.cached,
		answer.cost,
	)
}

// Group is one job's findings from one part of its subject, for the pass
// that checks them.
@(private)
Group :: struct {
	r:       ^Reviewer,
	j:       job.Job,
	subject: string,
	indexes: []int,
	result:  ^Result,
	lock:    ^sync.Mutex,
	drop:    ^map[int]bool,
}

// verify puts each job's findings back to the provider once, against the
// same evidence the first reading had, and keeps only the ones it also
// reports. A verdict that cannot be asked fails open: the findings stand,
// marked unverified, and the failure joins the others. A note is never
// gated on, so it stands unverified without a second reading.
@(private)
verify :: proc(
	r: ^Reviewer,
	tasks: []Task,
	result: ^Result,
	serial: bool,
	allocator := context.allocator,
) {
	groups := make([dynamic]Group, context.temp_allocator)
	lock: sync.Mutex
	drop := make(map[int]bool, context.temp_allocator)
	for t in tasks {
		for piece, part in t.pieces {
			indexes := make([dynamic]int, context.temp_allocator)
			for f, i in result.findings {
				if f.job == t.j.name && f.part == part && f.severity != .Note {
					append(&indexes, i)
				}
			}
			if len(indexes) > 0 {
				append(
					&groups,
					Group {
						r,
						t.j,
						t.j.subject(piece, context.temp_allocator),
						indexes[:],
						result,
						&lock,
						&drop,
					},
				)
			}
		}
	}
	if len(groups) == 0 {
		return
	}
	if serial {
		for &g in groups {
			judge(&g)
		}
	} else {
		threads := make([dynamic]^thread.Thread, context.temp_allocator)
		for &g in groups {
			ctx := runtime.default_context()
			ctx.allocator = allocator
			append(&threads, thread.create_and_start_with_poly_data(&g, judge, ctx))
		}
		for th in threads {
			thread.join(th)
			thread.destroy(th)
		}
	}
	// A retracted finding is out of the findings: it is reported as a
	// retraction, with its reason, not twice over.
	if len(drop) == 0 {
		return
	}
	survivors := make([dynamic]finding.Finding, allocator)
	for f, i in result.findings {
		if !drop[i] {
			append(&survivors, f)
		}
	}
	result.findings = survivors
}

// judge asks one group's verdicts and applies them.
@(private)
judge :: proc(g: ^Group) {
	held, answer, err := verdicts(g.r, g.j, g.subject, g.result.findings[:], g.indexes)
	sync.mutex_lock(g.lock)
	defer sync.mutex_unlock(g.lock)
	g.result.tokens_in += answer.tokens_in
	g.result.tokens_out += answer.tokens_out
	g.result.cached += answer.cached
	g.result.cost += answer.cost
	if answer.replayed {
		g.result.replayed += 1
	}
	if err != "" {
		append(&g.result.failures, fmt.aprintf("verify/%s: %s", g.j.name, err))
		for i in g.indexes {
			g.result.findings[i].verified = false
		}
		return
	}
	for i, position in g.indexes {
		if v, judged := held[position]; judged && !v.holds {
			append(
				&g.result.retracted,
				report.Retracted{finding = g.result.findings[i], reason = v.reason},
			)
			g.drop[i] = true
			continue
		}
		// A finding the verdict list omits stands rather than falls: a
		// strict pass would let one dropped number retract everything
		// the reading found.
		g.result.findings[i].verified = true
	}
}

// Verdict is what the second reading says about one finding.
Verdict :: struct {
	holds:  bool,
	reason: string,
}

// Spoken_Verdicts is the shape the second reading answers in.
Spoken_Verdicts :: struct {
	verdicts: []struct {
		index:  int `json:"index"`,
		holds:  bool `json:"holds"`,
		reason: string `json:"reason"`,
	} `json:"verdicts"`,
}

// readable_verdicts is whether an answer holds a verdicts object.
readable_verdicts :: proc(text: string) -> bool {
	raw, found := txt.object(text)
	if !found {
		return false
	}
	read: Spoken_Verdicts
	return json.unmarshal_string(raw, &read, allocator = context.temp_allocator) == nil
}

// verdicts puts one job's findings back to the provider, against the same
// evidence the first reading had. Verdicts are keyed by position in the
// listing; a position the answer omits stands rather than falls.
@(private)
verdicts :: proc(
	r: ^Reviewer,
	j: job.Job,
	subject: string,
	findings: []finding.Finding,
	indexes: []int,
) -> (
	held: map[int]Verdict,
	answer: provider.Answer,
	err: string,
) {
	system := strings.concatenate({verify_instruction, "\n\n", j.criteria}, context.temp_allocator)
	listed := strings.builder_make(context.temp_allocator)
	for i, position in indexes {
		f := findings[i]
		where_at := ""
		if f.file != "" {
			where_at = fmt.tprintf(" at %s:%d", f.file, f.line)
		}
		fmt.sbprintf(
			&listed,
			"%d. [%s] %s%s: %s\n   fix: %s\n",
			position,
			f.rule,
			finding.severity_name(f.severity),
			where_at,
			f.message,
			f.fix,
		)
	}
	user := strings.concatenate(
		{subject, "\n\nThe findings reported against it:\n\n", strings.to_string(listed)},
		context.temp_allocator,
	)
	answer, err = answered(r, system, user, true, readable_verdicts)
	if err != "" {
		return nil, answer, err
	}
	spent(r, j.name, answer)
	raised, found := txt.object(answer.text)
	if !found {
		prose := provider.first(answer.text, 200)
		answer, err = answered(
			r,
			system,
			strings.concatenate({user, "\n\n", verdicts_again}, context.temp_allocator),
			true,
			readable_verdicts,
		)
		if err != "" {
			return nil, answer, err
		}
		spent(r, j.name, answer)
		raised, found = txt.object(answer.text)
		if !found {
			return nil, answer, fmt.aprintf("no verdicts object in the answer, twice: %s", prose)
		}
	}
	read: Spoken_Verdicts
	if json.unmarshal_string(raised, &read, allocator = context.temp_allocator) != nil {
		return nil, answer, "the verdicts are not the shape asked for"
	}
	held = make(map[int]Verdict, context.temp_allocator)
	for v in read.verdicts {
		if v.index >= 0 && v.index < len(indexes) {
			held[v.index] = Verdict{v.holds, strings.clone(v.reason)}
		}
	}
	return held, answer, ""
}
