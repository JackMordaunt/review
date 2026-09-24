package hook

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "jm:sh"

@(test)
install_writes_the_hook_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root, err := os.make_directory_temp(temp, "review-hook-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	testing.expect(t, sh.exec({"git", "init", "-q"}, {dir = root}, context.temp_allocator).ok)
	// The tool's own git reads the real configuration, and a machine
	// with core.hooksPath set would send the install elsewhere.
	os.set_env("GIT_CONFIG_GLOBAL", "/dev/null")
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	defer os.unset_env("GIT_CONFIG_GLOBAL")
	defer os.unset_env("GIT_CONFIG_NOSYSTEM")
	before, _ := os.get_working_directory(context.temp_allocator)
	testing.expect(t, os.set_working_directory(root) == nil)
	defer os.set_working_directory(before)

	out, install_err := run({"install"})
	testing.expect_value(t, install_err, "")
	testing.expect(t, strings.contains(out, "PreToolUse"), "the harness stanza is printed")
	path := filepath.join({root, ".git", "hooks", "commit-msg"}, context.temp_allocator) or_else ""
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect(t, strings.has_prefix(string(data), "#!/bin/sh"))
	testing.expect(t, strings.contains(string(data), `--message-file "$1" --exit-code`))
	// A hook already there is someone's, and is not replaced unasked.
	_, again := run({"install"})
	testing.expect(t, strings.contains(again, "-force"))
	_, forced := run({"-force", "install"})
	testing.expect_value(t, forced, "")
	_, unknown := run({"dance"})
	testing.expect(t, strings.contains(unknown, "hook takes install or print"))
}

@(test)
print_and_agent_text_explain_the_gate :: proc(t: ^testing.T) {
	out, err := run({})
	defer delete(out)
	testing.expect_value(t, err, "")
	for want in ([]string{"commit-msg", "--exit-code", "PreToolUse", "review agent"}) {
		testing.expectf(t, strings.contains(out, want), "%q missing from hook print", want)
	}
	for want in ([]string{"review --json", "must-fix", "review:ignore", "--baseline"}) {
		testing.expectf(t, strings.contains(agent_text, want), "%q missing from agent text", want)
	}
}
