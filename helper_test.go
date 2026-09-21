package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// repo builds a git repository in a temporary directory, so that the parts of
// this tool that read a revision can be tested against real git output rather
// than a transcript of it.
type repo struct {
	t    *testing.T
	Root string
}

func newRepo(t *testing.T) *repo {
	t.Helper()
	r := &repo{t: t, Root: t.TempDir()}
	r.run("init", "-q", "-b", "main")
	r.run("config", "user.email", "test@example.com")
	r.run("config", "user.name", "Test")
	r.run("config", "commit.gpgsign", "false")
	return r
}

func (r *repo) run(args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = r.Root
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

// write puts a file in the working tree, creating the directories it needs.
func (r *repo) write(path, content string) {
	r.t.Helper()
	full := filepath.Join(r.Root, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// commit stages the named paths and records them.
func (r *repo) commit(message string, paths ...string) string {
	r.t.Helper()
	r.run(append([]string{"add", "--"}, paths...)...)
	r.run("commit", "-q", "-m", message)
	return strings.TrimSpace(r.run("rev-parse", "HEAD"))
}

// stage adds paths to the index without committing, which is what a bare
// review reads.
func (r *repo) stage(paths ...string) {
	r.t.Helper()
	r.run(append([]string{"add", "--"}, paths...)...)
}
