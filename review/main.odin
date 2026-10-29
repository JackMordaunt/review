// review, the Odin reading: what a change adds, read through the language
// sidecars, measured by the deterministic checks and the repository's
// analysers, judged by the model jobs, and reported. The change is the
// staged one, or the revision range given.
//
//	review [flags] [rev]
//	review rules [<rule>]
package main

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "core:strings"
import "jm:debug"

import "../analyser"
import "../bench"
import "../cache"
import "../cli"
import "../change"
import "../check"
import "../finding"
import "../git"
import "../hook"
import "../job"
import "../provider"
import "../report"
import "../reviewer"
import "../tree"


// The debug packages are wired in under ODIN_DEBUG below; the release
// build still names them, so the import stands in every configuration.
_ :: debug.Allocator
_ :: trace.assertion_failure_proc

Flags :: cli.Flags
parse :: cli.parse
json_failure :: cli.json_failure

main :: proc() {
	// Protocol stdout excludes debug allocator reports and update notices.
	if code, selected := cli.run_protocol(os.args[1:]); selected {os.exit(code)}
	// A debug build sets trace's assertion handler, and with
	// REVIEW_DEBUG_ALLOC set runs under the collection's debug allocator
	// and prints its report at exit; what the allocator detects is its own
	// header's to say. The report is asked for rather than printed on every
	// run, since a one-shot program leaves everything to exit. The release
	// build is untouched.
	when ODIN_DEBUG {
		context.assertion_failure_proc = trace.assertion_failure_proc
		if os.get_env("REVIEW_DEBUG_ALLOC", context.temp_allocator) != "" {
			da: debug.Allocator
			debug.init(&da, context.allocator)
			context.allocator = debug.allocator(&da)
			code := dispatch()
			debug.report(&da)
			debug.destroy(&da)
			os.exit(code)
		}
	}
	code := dispatch()
	notify_update()
	os.exit(code)
}

// dispatch is the program: a subcommand, or the review itself, returning
// the exit code.
dispatch :: proc() -> int {
	if len(os.args) > 1 {
		switch os.args[1] {
		case "rules":
			return print_rules(os.args[2:])
		case "hook":
			out, err := hook.run(os.args[2:])
			fmt.print(out)
			if err != "" {
				fmt.eprintfln("review: %s", err)
				return 1
			}
			return 0
		case "agent":
			fmt.print(hook.agent_text)
			return 0
		case "bench":
			return run_bench(os.args[2:])
		case "version", "--version", "-version":
			return print_version()
		case "update":
			return run_update()
		}
	}
	request := cli.read(os.args[1:])
	if !request.ok {
		json_failure(request.flags.as_json, "arguments", "invalid command arguments")
		return 2
	}
	if request.kind == .Doctor {return cli.doctor(request.flags)}
	return run(request.flags)
}

// run is the review: gather, read, measure, judge, report. It returns the
// exit code.
run :: proc(flags: Flags) -> int {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		fmt.eprintln("review: no working directory")
		json_failure(flags.as_json, "repository", "no working directory")
		return 2
	}
	if flags.repo != "" {cwd = flags.repo}
	root, in_repo := git.toplevel(cwd)
	if !in_repo {
		fmt.eprintln("review: not in a git repository")
		json_failure(flags.as_json, "repository", "not in a git repository")
		return 2
	}
	c, gathered := change.gather(flags.rev, root)
	if !gathered {
		fmt.eprintfln("review: git could not describe %q", flags.rev)
		json_failure(flags.as_json, "revision", fmt.tprintf("git could not describe %q", flags.rev))
		return 1
	}
	if flags.message_file != "" {
		message, read := change.read_message(flags.message_file)
		if !read {
			fmt.eprintfln("review: reading the message: %s", flags.message_file)
		json_failure(flags.as_json, "message", "could not read commit message")
			return 1
		}
		c.message = message
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
		json_failure(flags.as_json, "jobs", job_err)
		return 2
	}
	t, at_ok := tree.at(root, flags.rev)
	if !at_ok {
		fmt.eprintfln("review: could not materialise %q", flags.rev)
		json_failure(flags.as_json, "revision", "could not materialise revision")
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

	if flags.show && flags.as_json {
		json_failure(true, "arguments", "--show cannot be combined with --json")
		return 2
	}
	if flags.show {
		for j in jobs {
			pieces := job.parts(j, &c, context.temp_allocator)
			for piece, i in pieces {
				subject := j.subject(piece, context.temp_allocator)
				if len(pieces) > 1 {
					fmt.printfln("=== %s (part %d of %d) ===", j.name, i + 1, len(pieces))
				} else {
					fmt.printfln("=== %s ===", j.name)
				}
				if strings.trim_space(subject) == "" {
					fmt.print("(nothing to read)\n\n")
					continue
				}
				fmt.printfln("%s", subject)
			}
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
		fmt.eprintfln(
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
		json_failure(flags.as_json, "provider", provider_err)
		return 1
	}
	if flags.verbose {
		fmt.eprintfln("asking %s", picked)
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
	against: Maybe(report.Baseline)
	if flags.baseline_path != "" {
		b, cmp_err := report.compare(flags.baseline_path, kept)
		if cmp_err != "" {
			fmt.eprintfln("review: %s", cmp_err)
		json_failure(flags.as_json, "baseline", cmp_err)
			return 1
		}
		against = b
	}
	env := report.Contract {
		status = report.status_of(c, len(result.failures)),
		baseline = against,
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
		json_failure(flags.as_json, "encoding", "report could not be encoded")
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

// print_rules prints the catalogue, or one rule's description, so that an
// agent given a finding can read what it was judged against without
// leaving the terminal.
print_rules :: proc(args: []string) -> int {
	if len(args) > 0 && (args[0] == "-dismissed" || args[0] == "--dismissed") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		root, in_repo := git.toplevel(cwd)
		if !in_repo {
			fmt.eprintln("review: not in a git repository")
			return 2
		}
		t, _ := tree.at(root, "")
		fmt.print(check.dismissals(check.scope_of(nil, t)))
		return 0
	}
	if len(args) == 0 {
		fmt.print(check.catalogue())
		for j in job.all() {
			fmt.printfln("\n%s", j.criteria)
		}
		return 0
	}
	for j in job.all() {
		if j.name == args[0] {
			fmt.print(j.criteria)
			return 0
		}
	}
	if j, text, found := criterion(args[0]); found {
		fmt.printfln("%s, from the %s criteria:\n\n%s", args[0], j, text)
		return 0
	}
	description, ok := check.describe(args[0])
	if !ok {
		fmt.eprintfln(
			"review: no job or rule called %q; the jobs are claims, duplication, hygiene, namer, odin, stanzas, tests, artifacts",
			args[0],
		)
		return 1
	}
	fmt.printfln("%s, a deterministic check:\n\n%s", args[0], description)
	return 0
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

// run_bench measures the checks over recent commits and prints the fire
// rate per rule. It returns the exit code.
run_bench :: proc(args: []string) -> int {
	opts := bench.Options {
		n = 200,
	}
	root := ""
	i := 0
	for i < len(args) {
		take := proc(args: []string, i: ^int) -> string {
			if i^ + 1 < len(args) {
				i^ += 1
				return args[i^]
			}
			return ""
		}
		switch args[i] {
		case "-n", "--n":
			n := 0
			for c in take(args, &i) {
				if c >= '0' && c <= '9' {
					n = n * 10 + int(c - '0')
				}
			}
			if n > 0 {
				opts.n = n
			}
		case "-author", "--author":
			opts.author = take(args, &i)
		case "-fresh", "--fresh":
			opts.fresh = true
		case "-rule", "--rule":
			opts.rule = take(args, &i)
		case:
			root = args[i]
		}
		i += 1
	}
	if root == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		found: bool
		root, found = git.toplevel(cwd)
		if !found {
			fmt.eprintln("review: not in a git repository")
			return 2
		}
	}
	out, err := bench.run(
		root,
		opts,
		proc(done, total: int) {fmt.eprintf("\r  %d of %d", done, total)},
	)
	fmt.eprint("\r                \r")
	if err != "" {
		fmt.eprintfln("review: %s", err)
		return 1
	}
	fmt.print(out)
	return 0
}
