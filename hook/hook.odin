/*
Package hook is what makes the review a gate: a commit-msg hook, which
gates every agent that commits through git, and the stanza an agent's own
harness takes. The text an agent needs in its instructions is printed
from the binary too, so the tool explains itself wherever it is.
*/
package hook

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../git"

// run is the hook subcommand: install, or print.
run :: proc(args: []string) -> (out: string, err: string) {
	force := false
	verb := ""
	for arg in args {
		switch arg {
		case "-force", "--force":
			force = true
		case:
			verb = arg
		}
	}
	switch verb {
	case "install":
		return install(force)
	case "print", "":
		return text(), ""
	}
	return "", fmt.aprintf("hook takes install or print, not %q", verb)
}

// install writes the commit-msg hook into the repository, naming this
// binary by its absolute path so the hook works wherever the shell's path
// does not reach. A hook already there is not overwritten unasked: it is
// someone's, and it may do more than this.
install :: proc(force: bool) -> (out: string, err: string) {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		return "", "no working directory"
	}
	root, in_repo := git.toplevel(cwd, context.temp_allocator)
	if !in_repo {
		return "", "not in a git repository"
	}
	// With core.hooksPath set, git reads hooks from one directory for
	// every repository and ignores .git/hooks. Writing there would change
	// every repository on the machine, and writing to .git/hooks would
	// change nothing; neither is this tool's to do unasked.
	if shared, set := git.run(root, {"config", "--get", "core.hooksPath"}, context.temp_allocator);
	   set && strings.trim_space(shared) != "" {
		where_at := strings.trim_space(shared)
		return commit_msg_hook(
			
		), fmt.aprintf("core.hooksPath is %s, so git reads hooks there and not from .git/hooks; add the exec line above to %s/commit-msg yourself", where_at, where_at)
	}
	dir, found := git.run(root, {"rev-parse", "--git-path", "hooks"}, context.temp_allocator)
	if !found {
		return "", "git names no hooks directory"
	}
	dir = strings.trim_space(dir)
	if !os.is_absolute_path(dir) {
		dir = filepath.join({root, dir}, context.temp_allocator) or_else dir
	}
	path := filepath.join({dir, "commit-msg"}, context.temp_allocator) or_else ""
	if os.exists(path) && !force {
		return "", fmt.aprintf("%s exists; read it, then pass -force to replace it", path)
	}
	if !os.is_dir(dir) && os.make_directory_all(dir) != nil {
		return "", fmt.aprintf("cannot make %s", dir)
	}
	if os.write_entire_file(
		   path,
		   transmute([]byte)commit_msg_hook(),
		   os.Permissions_Read_All + {.Write_User} + os.Permissions_Execute_All,
	   ) !=
	   nil {
		return "", fmt.aprintf("cannot write %s", path)
	}
	return fmt.aprintf("wrote %s\n\n%s", path, agent_stanza()), ""
}

// self is the absolute path of the running binary, or its bare name where
// that cannot be known.
self :: proc(allocator := context.allocator) -> string {
	exe, err := os.get_executable_path(allocator)
	if err != nil {
		return "review"
	}
	return exe
}

// commit_msg_hook is the hook git runs with the proposed message's file:
// the staged change is reviewed with that message, and a must-fix finding
// refuses the commit.
commit_msg_hook :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"#!/bin/sh\n# Installed by review. The staged change is reviewed with the message being\n# committed; a must-fix finding that stands refuses the commit. Dismiss a\n# finding where it is wrong, in the source: //review:ignore <rule> <why>\nexec %q --message-file \"$1\" --exit-code\n",
		self(context.temp_allocator),
		allocator = allocator,
	)
}

// text is everything hook print shows: the git hook and the harness
// stanzas.
text :: proc(allocator := context.allocator) -> string {
	return strings.concatenate(
		{
			"# .git/hooks/commit-msg — or run: review hook install\n",
			commit_msg_hook(context.temp_allocator),
			"\n",
			agent_stanza(context.temp_allocator),
		},
		allocator,
	)
}

// agent_stanza is the hook an agent's harness takes, for the harnesses
// whose shape is known. Claude Code and Grok run a PreToolUse hook before
// each tool call, and take one file shape (Claude Code's hooks and Grok's
// 10-hooks guide, grok 1.0.62, both say so); the command below reviews the
// staged change when the call is a git commit. Only exit 2 stops the call,
// with stderr as the reason, so the review's exit 1 is turned into one and
// its report moved to stderr.
agent_stanza :: proc(allocator := context.allocator) -> string {
	return strings.concatenate(
		{
			"# Claude Code: .claude/settings.json (or ~/.claude/settings.json)\n",
			"# Grok: ~/.grok/hooks/review.json, or the same file as Claude's: Grok reads\n",
			"# ~/.claude/settings.json too.\n",
			"# Reviews the staged change before any \"git commit\" the agent runs.\n",
			"{\n  \"hooks\": {\n    \"PreToolUse\": [{\n      \"matcher\": \"Bash\",\n      \"hooks\": [{\n        \"type\": \"command\",\n",
			"        \"command\": \"if grep -q 'git commit' ; then ",
			self(context.temp_allocator),
			" --exit-code >&2 || exit 2; fi\"\n",
			"      }]\n    }]\n  }\n}\n\n",
			"# Any other agent, Codex included: the commit-msg hook above gates every\n",
			"# commit it makes through git, whatever harness it runs in. Put the output of\n#   review agent\n",
			"# in its instructions (AGENTS.md for Codex) so it knows what the refusal means\n",
			"# and how to answer it.\n",
		},
		allocator,
	)
}

// agent_text is what an agent's instructions should say about this tool:
// how to run it, how to read it, how to answer it, and when it may stop.
agent_text ::
	`## Code review

Before committing, run ` +
	"`review --json`" +
	` on the staged change and act on the report.

- ` +
	"`status`" +
	` is ` +
	"`complete`" +
	` when every reader read everything. An empty findings list
  under any other status is a hole, not a pass.
- Every finding carries a stable ` +
	"`id`" +
	`, a ` +
	"`rule`" +
	`, a ` +
	"`severity`" +
	`, the ` +
	"`file`" +
	` and
  ` +
	"`line`" +
	`, the ` +
	"`snippet`" +
	` at that line, and a ` +
	"`fix`" +
	`: the concrete change to make.
  Read the rule with ` +
	"`review rules <rule>`" +
	` when the finding is unclear.
- Fix every ` +
	"`must-fix`" +
	`. Weigh each ` +
	"`consider`" +
	`. A ` +
	"`note`" +
	` needs no action.
- Where a finding is wrong, dismiss it in the source it concerns, on the line
  above, with the reason: ` +
	"`//review:ignore <rule> <why>`" +
	`. Never dismiss to pass.
  Review reports reasoned, rule-specific dismissals as consider so the person
  reviewing can assess them; blanket or unexplained dismissals are must-fix.
- Re-run with ` +
	"`--baseline previous.json`" +
	` to see which ids resolved, persist or
  are new. Stop when nothing must-fix persists and the status is complete.
- Never delete a test to pass the review; deleting one is a must-fix finding.
- The commit message is measured too: ` +
	"`package: explainer`" +
	`, the explainer in
  the imperative, a body saying why for any change over fifty lines, under 150
  words, naming only code that exists.
`
