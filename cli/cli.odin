// Package cli maps invocation strings to typed command requests.
package cli

import "core:fmt"
import "core:os"
import "core:strings"

usage :: `review reads a change the way several narrow readers would.

usage: review [flags] [rev]      the staged change, or a revision range
       review rules [<rule>]     the deterministic checks, or one of them
       review rules -dismissed   the dismissals in the tree, per rule
       review hook [install]     the commit-msg hook, printed or installed
       review agent              what an agent's instructions should say
       review bench [-n N] [-author A] [-rule R] [--fresh] [root]
                                 the checks' fire rate over recent commits
       review doctor [--json] [--repo path]  local paths and capability diagnostics
       review version            which release this is
       review update             fetch the latest release and replace these binaries

  --repo path      Read this repository instead of the working directory.
  --json           Report findings as JSON, for an agent rather than a person.
  --verbose        Show what each job read and what it cost.
  --show           Print what each job would be sent and stop, without asking anything.
  --no-verify      Skip the second reading that checks what each job reported.
  --fresh          Ask the provider even where the answer cache holds this exact question.
  --exit-code      Exit 1 when a must-fix finding stands, so a hook can refuse the change.
  --message-file f Read the commit message from this file, as a commit-msg hook is given it.
  --baseline f     A previous --json report; each finding is then new, persisting or resolved against it.
  --jobs a,b       Run only these jobs, comma separated.
  --provider p     Who answers: chain (probe the default order), claude, grok, pi, api, or command.
  --model m        Which model, in whatever form the provider names them.
`

Flags :: struct {
	as_json, verbose, show, no_verify, fresh, exit_code:  bool,
	only, which, model, rev, message_file, baseline_path, repo: string,
}

Kind :: enum {Review, Doctor}
Request :: struct {kind: Kind, flags: Flags, ok: bool}

read :: proc(args: []string, allocator := context.temp_allocator) -> Request {
	kind := Kind.Review
	values := args
	if len(args) > 0 && args[0] == "doctor" {
		kind = .Doctor
		values = args[1:]
	}
	flags, ok := parse(values, allocator)
	return Request{kind, flags, ok}
}

// parse reads the flags. A flag that takes a value takes the next argument
// or the part after its equals sign.
parse :: proc(args: []string, allocator := context.temp_allocator) -> (flags: Flags, ok: bool) {
	flags.which = os.get_env("REVIEW_PROVIDER", allocator)
	if flags.which == "" {
		flags.which = "chain"
	}
	flags.model = os.get_env("REVIEW_MODEL", allocator)
	for arg in args {
		if arg == "--json" || arg == "-json" {flags.as_json = true}
	}
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
		case "--message-file", "-message-file":
			flags.message_file = take(args, &i, value)
		case "--repo":
			flags.repo = take(args, &i, value)
			if flags.repo == "" {return flags, false}
		case "--baseline", "-baseline":
			flags.baseline_path = take(args, &i, value)
		case "-h", "--help", "-help":
			if flags.as_json {fmt.eprint(usage)} else {fmt.print(usage)}
			return flags, false
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintfln("review: unknown flag %s", arg)
				fmt.eprint(usage)
				return flags, false
			}
			flags.rev = arg
		}
		switch name {
		case "--repo", "--jobs", "-jobs", "--provider", "-provider", "--model", "-model", "--message-file", "-message-file", "--baseline", "-baseline":
			if (value == "" && (i >= len(args) || strings.has_prefix(args[i], "-"))) || strings.has_suffix(arg, "=") {
				fmt.eprintfln("review: missing value for %s", name)
				return flags, false
			}
		}
		i += 1
	}
	return flags, true
}
