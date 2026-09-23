package main

// The review forces nothing until something runs it and refuses on its
// word. The hooks here are that something: a commit-msg hook, which gates
// every agent that commits through git, and the stanza an agent's own
// harness takes. The text an agent needs in its instructions is printed
// from the binary too, so the tool explains itself wherever it is.

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// hook installs or prints the hooks that make the review a gate.
func hook(args []string) error {
	flags := flag.NewFlagSet("hook", flag.ContinueOnError)
	force := flags.Bool("force", false, "Replace a commit-msg hook that is already there.")
	if err := flags.Parse(args); err != nil {
		return err
	}
	switch flags.Arg(0) {
	case "install":
		return installHook(*force)
	case "print", "":
		fmt.Print(hookText())
		return nil
	}
	return fmt.Errorf("hook takes install or print, not %q", flags.Arg(0))
}

// installHook writes the commit-msg hook into the repository, naming this
// binary by its absolute path so the hook works wherever the shell's path
// does not reach. A hook already there is not overwritten unasked: it is
// someone's, and it may do more than this.
func installHook(force bool) error {
	root, err := repository()
	if err != nil {
		return err
	}
	// With core.hooksPath set, git reads hooks from one directory for every
	// repository and ignores .git/hooks. Writing there would change every
	// repository on the machine, and writing to .git/hooks would change
	// nothing; neither is this tool's to do unasked.
	if shared, err := git(root, "config", "--get", "core.hooksPath"); err == nil && strings.TrimSpace(shared) != "" {
		fmt.Print(commitMsgHook())
		return fmt.Errorf("core.hooksPath is %s, so git reads hooks there and not from .git/hooks; add the exec line above to %s/commit-msg yourself",
			strings.TrimSpace(shared), strings.TrimSpace(shared))
	}
	dir, err := git(root, "rev-parse", "--git-path", "hooks")
	if err != nil {
		return err
	}
	dir = strings.TrimSpace(dir)
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(root, dir)
	}
	path := filepath.Join(dir, "commit-msg")
	if _, err := os.Stat(path); err == nil && !force {
		return fmt.Errorf("%s exists; read it, then pass -force to replace it", path)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(commitMsgHook()), 0o755); err != nil {
		return err
	}
	fmt.Printf("wrote %s\n\n", path)
	fmt.Print(agentStanza())
	return nil
}

// self is the absolute path of the running binary, or its bare name where
// that cannot be known.
func self() string {
	exe, err := os.Executable()
	if err != nil {
		return "review"
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return exe
}

// commitMsgHook is the hook git runs with the proposed message's file: the
// staged change is reviewed with that message, and a must-fix finding
// refuses the commit.
func commitMsgHook() string {
	return fmt.Sprintf(`#!/bin/sh
# Installed by review. The staged change is reviewed with the message being
# committed; a must-fix finding that stands refuses the commit. Dismiss a
# finding where it is wrong, in the source: //review:ignore <rule> <why>
exec %q --message-file "$1" --exit-code
`, self())
}

// hookText is everything hook print shows: the git hook and the harness
// stanzas.
func hookText() string {
	return "# .git/hooks/commit-msg — or run: review hook install\n" + commitMsgHook() + "\n" + agentStanza()
}

// agentStanza is the hook an agent's harness takes, for the harnesses whose
// shape is known. Claude Code runs a PreToolUse hook before each tool call;
// the one below reviews the staged change when the call is a git commit,
// and a non-zero exit stops the call with the review's output as the reason.
func agentStanza() string {
	return fmt.Sprintf(`# Claude Code: .claude/settings.json (or ~/.claude/settings.json)
# Reviews the staged change before any "git commit" the agent runs.
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "if grep -q 'git commit' ; then %s --exit-code; fi"
      }]
    }]
  }
}

# Any other agent: the commit-msg hook above gates every commit it makes
# through git, whatever harness it runs in. Put the output of
#   review agent
# in its instructions so it knows what the refusal means and how to answer it.
`, self())
}

// agent prints what an agent's instructions should say about this tool: how
// to run it, how to read it, how to answer it, and when it may stop.
func agent() error {
	fmt.Print(agentText())
	return nil
}

func agentText() string {
	return `## Code review

Before committing, run ` + "`review --json`" + ` on the staged change and act on the report.

- ` + "`status`" + ` is ` + "`complete`" + ` when every reader read everything. An empty findings list
  under any other status is a hole, not a pass.
- Every finding carries a stable ` + "`id`" + `, a ` + "`rule`" + `, a ` + "`severity`" + `, the ` + "`file`" + ` and
  ` + "`line`" + `, the ` + "`snippet`" + ` at that line, and a ` + "`fix`" + `: the concrete change to make.
  Read the rule with ` + "`review rules <rule>`" + ` when the finding is unclear.
- Fix every ` + "`must-fix`" + `. Weigh each ` + "`consider`" + `. A ` + "`note`" + ` needs no action.
- Where a finding is wrong, dismiss it in the source it concerns, on the line
  above, with the reason: ` + "`//review:ignore <rule> <why>`" + `. Never dismiss to pass;
  a dismissal added by the change under review is itself a must-fix finding.
- Re-run with ` + "`--baseline previous.json`" + ` to see which ids resolved, persist or
  are new. Stop when nothing must-fix persists and the status is complete.
- Never delete a test to pass the review; deleting one is a must-fix finding.
- The commit message is measured too: ` + "`package: explainer`" + `, the explainer in
  the imperative, a body saying why for any change over fifty lines, under 150
  words, naming only code that exists.
`
}
