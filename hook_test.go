package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHookInstall(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	t.Chdir(r.Root)
	// The tool's own git reads the real configuration, and a machine with
	// core.hooksPath set would send the install elsewhere.
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	out := capture(t, func() {
		if err := hook([]string{"install"}); err != nil {
			t.Fatal(err)
		}
	})
	path := filepath.Join(r.Root, ".git", "hooks", "commit-msg")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `--message-file "$1" --exit-code`) || !strings.HasPrefix(string(data), "#!/bin/sh") {
		t.Errorf("hook:\n%s", data)
	}
	if info, _ := os.Stat(path); info.Mode()&0o100 == 0 {
		t.Error("the hook is not executable")
	}
	if !strings.Contains(out, "PreToolUse") {
		t.Errorf("the harness stanza was not printed:\n%s", out)
	}
	// A hook already there is someone's, and is not replaced unasked.
	if err := hook([]string{"install"}); err == nil || !strings.Contains(err.Error(), "-force") {
		t.Errorf("an existing hook was replaced: %v", err)
	}
	if err := hook([]string{"-force", "install"}); err != nil {
		t.Errorf("force: %v", err)
	}
	if err := hook([]string{"dance"}); err == nil {
		t.Error("an unknown verb was accepted")
	}
}

func TestHookPrintAndAgentText(t *testing.T) {
	out := capture(t, func() {
		if err := hook(nil); err != nil {
			t.Fatal(err)
		}
	})
	for _, want := range []string{"commit-msg", "--exit-code", "PreToolUse", "review agent"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q missing from hook print", want)
		}
	}
	text := capture(t, func() {
		if err := agent(); err != nil {
			t.Fatal(err)
		}
	})
	for _, want := range []string{"review --json", "`status`", "review rules <rule>", "review:ignore", "--baseline", "Never delete a test"} {
		if !strings.Contains(text, want) {
			t.Errorf("%q missing from the agent text", want)
		}
	}
}

// A machine whose hooks live in one shared directory is not written to:
// the hook is printed, and the refusal says where it goes.
func TestHookInstallRefusesASharedHooksPath(t *testing.T) {
	r := newRepo(t)
	r.write("x.go", "package x\n")
	r.commit("first", "x.go")
	r.run("config", "core.hooksPath", filepath.Join(r.Root, "shared-hooks"))
	t.Chdir(r.Root)
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	var err error
	out := capture(t, func() { err = hook([]string{"install"}) })
	if err == nil || !strings.Contains(err.Error(), "core.hooksPath") {
		t.Fatalf("installed under a shared hooks path: %v", err)
	}
	if !strings.Contains(out, "--message-file") {
		t.Errorf("the hook was not printed for the user to place:\n%s", out)
	}
	if _, statErr := os.Stat(filepath.Join(r.Root, ".git", "hooks", "commit-msg")); statErr == nil {
		t.Error("a hook git would ignore was written")
	}
}
