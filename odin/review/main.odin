// review, the Odin reading: what a change adds, read through the language
// sidecars, judged, and reported. The change is the staged one, or the
// revision range given.
//
//	review [--json] [--verbose] [--show] [rev]
//	review rules [<rule>]
package main

import "core:fmt"
import "core:os"

import "../change"
import "../check"
import "../finding"
import "../git"
import "../report"
import "../tree"

main :: proc() {
	as_json, verbose, show: bool
	rev := ""
	if len(os.args) > 1 && os.args[1] == "rules" {
		rules(os.args[2:])
		return
	}
	for arg in os.args[1:] {
		switch arg {
		case "--json":
			as_json = true
		case "--verbose":
			verbose = true
		case "--show":
			show = true
		case "-h", "--help":
			fmt.println("usage: review [--json] [--verbose] [--show] [rev]")
			return
		case:
			rev = arg
		}
	}
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		fmt.eprintln("review: no working directory")
		os.exit(2)
	}
	root, in_repo := git.toplevel(cwd)
	if !in_repo {
		fmt.eprintln("review: not in a git repository")
		os.exit(2)
	}
	c, gathered := change.gather(rev, root)
	if !gathered {
		fmt.eprintfln("review: git could not describe %q", rev)
		os.exit(1)
	}
	if len(c.files) == 0 {
		if as_json {
			out, _ := report.encode(report.Contract{status = "empty"})
			fmt.println(out)
		} else {
			fmt.println("nothing to review")
		}
		return
	}
	t, at_ok := tree.at(root, rev)
	if !at_ok {
		fmt.eprintfln("review: could not materialise %q", rev)
		os.exit(1)
	}
	defer tree.close(t)

	change.read(&c, t)
	c.index, _ = change.index(t)
	if show {
		list(c, t)
	}
	// The deterministic checks ask nothing of a provider, so they run
	// before one is built and survive a model that cannot answer.
	findings := check.run(check.scope_of(&c, t))
	finding.sort(findings)
	kept, dismissed := report.filter(t.dir, findings)
	env := report.Contract {
		status    = report.status_of(c, 0),
		findings  = kept,
		dismissed = dismissed,
		uncovered = c.uncovered[:],
		truncated = c.truncated,
	}
	if as_json {
		out, ok := report.encode(env)
		if !ok {
			fmt.eprintln("review: the report could not be encoded")
			os.exit(1)
		}
		fmt.println(out)
		return
	}
	fmt.print(report.render(env, verbose))
	for gap in c.uncovered {
		fmt.eprintfln("unread: %s: %s", gap.file, gap.reason)
	}
}

// list prints what the sidecars read, for a look at the evidence before
// any judgement of it.
list :: proc(c: change.Change, t: tree.Tree) {
	added := 0
	for _, lines in c.added {
		added += len(lines)
	}
	fmt.printfln("=== change: %d files, %d added lines ===", len(c.files), added)
	for s in c.symbols {
		mark := " exported" if s.exported else ""
		fmt.printfln("symbol  %s:%d %s %s%s", s.file, s.line, s.kind, s.name, mark)
	}
	for f in c.tests {
		fmt.printfln("test    %s:%d %s", f.file, f.line, f.name)
	}
	for l in c.comments {
		fmt.printfln("comment %s:%d %s", l.file, l.line, l.text)
	}
	fmt.printfln("=== index: %d declarations ===", len(c.index))
}

// rules prints the catalogue, or one rule's description, so that an
// agent given a finding can read what it was judged against without
// leaving the terminal.
rules :: proc(args: []string) {
	if len(args) == 0 {
		fmt.print(check.catalogue())
		return
	}
	description, ok := check.describe(args[0])
	if !ok {
		fmt.eprintfln("review: no rule called %q", args[0])
		os.exit(1)
	}
	fmt.printfln("%s, a deterministic check:\n\n%s", args[0], description)
}
