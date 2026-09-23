// review, the Odin reading: what a change adds, read through the language
// sidecars, measured by the deterministic checks and the repository's
// analysers, judged by the model jobs, and reported. The change is the
// staged one, or the revision range given.
//
//	review [flags] [rev]
//	review rules [<rule>]
package main

import "core:fmt"
import "core:os"
import "core:strings"

import "../analyser"
import "../cache"
import "../change"
import "../check"
import "../finding"
import "../git"
import "../job"
import "../provider"
import "../report"
import "../reviewer"
import "../tree"

usage :: `review reads a change the way several narrow readers would.

usage: review [flags] [rev]      the staged change, or a revision range
       review rules [<rule>]     the deterministic checks, or one of them

  --json           Report findings as JSON, for an agent rather than a person.
  --verbose        Show what each job read and what it cost.
  --show           Print what each job would be sent and stop, without asking anything.
  --no-verify      Skip the second reading that checks what each job reported.
  --fresh          Ask the provider even where the answer cache holds this exact question.
  --exit-code      Exit 1 when a must-fix finding stands, so a hook can refuse the change.
  --jobs a,b       Run only these jobs, comma separated.
  --provider p     Who answers: chain (probe the default order), claude, pi, api, or command.
  --model m        Which model, in whatever form the provider names them.
`

Flags :: struct {
	as_json, verbose, show, no_verify, fresh, exit_code: bool,
	only, which, model, rev:                             string,
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "rules" {
		rules(os.args[2:])
		return
	}
	flags, ok := parse(os.args[1:])
	if !ok {
		os.exit(2)
	}
	code := run(flags)
	os.exit(code)
}

// parse reads the flags. A flag that takes a value takes the next argument
// or the part after its equals sign.
parse :: proc(args: []string) -> (flags: Flags, ok: bool) {
	flags.which = os.get_env("REVIEW_PROVIDER", context.temp_allocator)
	if flags.which == "" {
		flags.which = "chain"
	}
	flags.model = os.get_env("REVIEW_MODEL", context.temp_allocator)
	i := 0
	for i < len(args) {
		arg := args[i]
		name, value := arg, ""
		if eq := strings.index_byte(arg, '='); eq >= 0 && strings.has_prefix(arg, "-") {
			name, value = arg[:eq], arg[eq + 1:]
		}
		take := proc(args: []string, i: ^int, value: string) -> string {
			if value != "" {
				return value
			}
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^]
			}
			return ""
		}
		switch name {
		case "--json", "-json":
			flags.as_json = true
		case "--verbose", "-verbose":
			flags.verbose = true
		case "--show", "-show":
			flags.show = true
		case "--no-verify", "-no-verify":
			flags.no_verify = true
		case "--fresh", "-fresh":
			flags.fresh = true
		case "--exit-code", "-exit-code":
			flags.exit_code = true
		case "--jobs", "-jobs":
			flags.only = take(args, &i, value)
		case "--provider", "-provider":
			flags.which = take(args, &i, value)
		case "--model", "-model":
			flags.model = take(args, &i, value)
		case "-h", "--help", "-help":
			fmt.print(usage)
			return flags, false
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintfln("review: unknown flag %s", arg)
				fmt.eprint(usage)
				return flags, false
			}
			flags.rev = arg
		}
		i += 1
	}
	return flags, true
}

// run is the review: gather, read, measure, judge, report. It returns the
// exit code.
run :: proc(flags: Flags) -> int {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		fmt.eprintln("review: no working directory")
		return 2
	}
	root, in_repo := git.toplevel(cwd)
	if !in_repo {
		fmt.eprintln("review: not in a git repository")
		return 2
	}
	c, gathered := change.gather(flags.rev, root)
	if !gathered {
		fmt.eprintfln("review: git could not describe %q", flags.rev)
		return 1
	}
	if strings.trim_space(c.diff) == "" {
		if flags.as_json {
			out, _ := report.encode(report.Contract{status = "empty"})
			fmt.println(out)
		} else {
			fmt.println("nothing to review")
		}
		return 0
	}
	jobs, job_err := job.chosen(flags.only)
	if job_err != "" {
		fmt.eprintfln("review: %s", job_err)
		return 2
	}
	t, at_ok := tree.at(root, flags.rev)
	if !at_ok {
		fmt.eprintfln("review: could not materialise %q", flags.rev)
		return 1
	}
	defer tree.close(t)

	change.read(&c, t)
	c.index, _ = change.index(t)
	change.find_candidates(&c)
	// The deterministic checks ask nothing of a provider, so they run
	// before one is built and survive a model that cannot answer.
	static := make([dynamic]finding.Finding)
	append(&static, ..check.run(check.scope_of(&c, t)))
	_, ranged := tree.ends(flags.rev)
	append(&static, ..analyser.check(&c, t, ranged))

	if flags.show {
		for j in jobs {
			subject := j.subject(&c, context.temp_allocator)
			fmt.printfln("=== %s ===", j.name)
			if strings.trim_space(subject) == "" {
				fmt.print("(nothing to read)\n\n")
				continue
			}
			fmt.printfln("%s", subject)
		}
		fmt.println("=== static ===")
		kept, _ := report.filter(t.dir, static[:])
		finding.sort(kept)
		if len(kept) == 0 {
			fmt.println("(no findings)")
		}
		for f in kept {
			line, _ := strings.replace_all(
				finding.to_string(f, context.temp_allocator),
				"\n      ",
				"\n    ",
				context.temp_allocator,
			)
			fmt.printfln("  %s", line)
		}
		return 0
	}
	if flags.verbose {
		fmt.printfln(
			"reviewing %d files, %d new names, %d tests, %d comments",
			len(c.files),
			len(c.symbols),
			len(c.tests),
			len(c.comments),
		)
	}

	who, picked, provider_err := choose(flags)
	if provider_err != "" {
		fmt.eprintfln("review: %s", provider_err)
		return 1
	}
	if flags.verbose {
		fmt.printfln("asking %s", picked)
	}
	// The cache records what each ask answered, so that a re-run of a
	// part of the change that did not change replays it instead of
	// asking. A cache that cannot exist is no fault of the review.
	answers, _ := cache.open(flags.fresh)
	defer cache.save(answers)
	r := reviewer.Reviewer {
		provider = who,
		name     = provider.name(who),
		verify   = !flags.no_verify,
		verbose  = flags.verbose,
		cache    = answers,
	}
	result := reviewer.run(&r, &c, jobs)

	findings := make([dynamic]finding.Finding)
	append(&findings, ..result.findings[:])
	append(&findings, ..static[:])
	kept, dismissed := report.filter(t.dir, findings[:])
	finding.sort(kept)
	for &f in kept {
		if f.file != "" && f.line > 0 {
			f.snippet = tree.line(t, f.file, f.line)
		}
	}
	env := report.Contract {
		status = report.status_of(c, len(result.failures)),
		provider = r.name,
		findings = kept,
		retracted = result.retracted[:],
		failed = faults(result.failures[:]),
		skipped = result.skipped[:],
		uncovered = c.uncovered[:],
		dismissed = dismissed,
		truncated = c.truncated,
		usage = {
			tokens_in = result.tokens_in,
			tokens_out = result.tokens_out,
			cached = result.cached,
			replayed = result.replayed,
			cost = result.cost,
		},
	}
	if flags.as_json {
		out, encoded := report.encode(env)
		if !encoded {
			fmt.eprintln("review: the report could not be encoded")
			return 1
		}
		fmt.println(out)
	} else {
		for failure in result.failures {
			fmt.eprintfln("  job failed: %s", failure)
		}
		fmt.print(report.render(env, flags.verbose))
		for gap in c.uncovered {
			fmt.eprintfln("unread: %s: %s", gap.file, gap.reason)
		}
	}
	// The review is advisory unless asked to gate: then a must-fix
	// finding that stands is the one thing it refuses.
	if flags.exit_code && finding.must_fix(kept) {
		return 1
	}
	return 0
}

// choose is the provider the flags name, or the first of the default
// chain that answers a probe.
choose :: proc(flags: Flags) -> (who: provider.Provider, picked: string, err: string) {
	if flags.which == "chain" {
		return provider.pick(provider.default_chain(), proc(msg: string) {fmt.eprintln(msg)})
	}
	built, known := provider.build(flags.which, flags.model)
	if !known {
		return {}, "", fmt.aprintf("no provider called %q", flags.which)
	}
	return built, provider.name(built), ""
}

// faults pairs each failure's job with what failed about it.
faults :: proc(failures: []string) -> []report.Job_Fault {
	out := make([]report.Job_Fault, len(failures))
	for f, i in failures {
		if sep := strings.index(f, ": "); sep >= 0 {
			out[i] = report.Job_Fault{f[:sep], f[sep + 2:]}
		} else {
			out[i] = report.Job_Fault{f, f}
		}
	}
	return out
}

// rules prints the catalogue, or one rule's description, so that an
// agent given a finding can read what it was judged against without
// leaving the terminal.
rules :: proc(args: []string) {
	if len(args) == 0 {
		fmt.print(check.catalogue())
		for j in job.all() {
			fmt.printfln("\n%s", j.criteria)
		}
		return
	}
	for j in job.all() {
		if j.name == args[0] {
			fmt.print(j.criteria)
			return
		}
	}
	if j, text, found := criterion(args[0]); found {
		fmt.printfln("%s, from the %s criteria:\n\n%s", args[0], j, text)
		return
	}
	description, ok := check.describe(args[0])
	if !ok {
		fmt.eprintfln(
			"review: no job or rule called %q; the jobs are claims, duplication, hygiene, namer, tests",
			args[0],
		)
		os.exit(1)
	}
	fmt.printfln("%s, a deterministic check:\n\n%s", args[0], description)
}

// criterion finds the bullet that defines a rule, in whichever job's
// criteria holds it, with the lines that continue it.
criterion :: proc(id: string) -> (name, text: string, found: bool) {
	marker := strings.concatenate({"- `", id, "`"}, context.temp_allocator)
	for j in job.all() {
		lines := strings.split_lines(j.criteria, context.temp_allocator)
		for line, i in lines {
			if !strings.has_prefix(line, marker) {
				continue
			}
			kept := make([dynamic]string, context.temp_allocator)
			for l in lines[i:] {
				if len(kept) > 0 && !strings.has_prefix(l, "  ") {
					break
				}
				append(&kept, l)
			}
			return j.name, strings.join(kept[:], "\n", context.temp_allocator), true
		}
	}
	return "", "", false
}
