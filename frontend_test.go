package main

import (
	"os"
	"strings"
	"testing"
)

// captureStderr swaps stderr for a pipe while the work runs, so a test can
// read what the gatherer told the user.
func captureStderr(t *testing.T, work func()) string {
	t.Helper()
	real := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	work()
	w.Close()
	os.Stderr = real
	var out strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		out.Write(buf[:n])
		if err != nil {
			break
		}
	}
	return out.String()
}

func TestHeuristicReadsOdinComments(t *testing.T) {
	r := newRepo(t)
	r.write("heimdall/main.odin", `package main

import "core:fmt"

main :: proc() {
	fmt.println("hello")
	// counts the icons a binary carries
}
`)
	r.commit("main: hello", "heimdall/main.odin")
	r.write("heimdall/main.odin", `package main

import "core:fmt"

// across the whole window
main :: proc() {
	fmt.println("goodbye")
}
`)
	r.stage("heimdall/main.odin")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Comments) != 1 || change.Comments[0].Text != "across the whole window" {
		t.Fatalf("comments %v, want the one added comment", change.Comments)
	}
}

func TestHeuristicKeepsBlockCommentsWhole(t *testing.T) {
	r := newRepo(t)
	r.write("f/open.c", "int open(void) { return 0; }\n")
	r.commit("f: open", "f/open.c")
	r.write("f/open.c", `/* reads the icons
   a binary carries */
int open(void) { return 1; }
`)
	r.stage("f/open.c")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Comments) != 2 {
		t.Fatalf("comments %v, want both block lines", change.Comments)
	}
	if change.Comments[0].Text != "reads the icons" || change.Comments[1].Text != "a binary carries" {
		t.Fatalf("comments %q, %q", change.Comments[0].Text, change.Comments[1].Text)
	}
}

func TestHeuristicLeavesProseAlone(t *testing.T) {
	r := newRepo(t)
	r.write("f/open.c", "int open(void) { return 0; }\n")
	r.commit("f: open", "f/open.c")
	r.write("f/open.c", "#!/usr/bin/env runtime\nint open(void) { return 1; }\n")
	r.stage("f/open.c")

	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Comments) != 0 {
		t.Fatalf("comments %v, want a shebang rejected", change.Comments)
	}
}

func TestHeuristicLogsTheSkips(t *testing.T) {
	r := newRepo(t)
	r.write("f/main.rs", "fn main() {}\n")
	r.commit("f: empty", "f/main.rs")
	r.write("f/main.rs", "fn main() { }\n")
	r.stage("f/main.rs")

	var logged string
	change, err := Gather("", r.Root)
	if err != nil {
		t.Fatal(err)
	}
	logged = captureStderr(t, func() {
		change.read(r.Root, "", frontends())
	})
	if !strings.Contains(logged, "skipping duplication, namer for .rs") {
		t.Fatalf("logged %q, want the duplication and namer skip", logged)
	}
	if !strings.Contains(logged, "skipping tests for .rs") {
		t.Fatalf("logged %q, want the tests skip", logged)
	}
	if strings.Contains(logged, "skipping claims") {
		t.Fatalf("logged %q, want claims served", logged)
	}
}
