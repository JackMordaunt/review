package change

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "jm:sh"

import "../frontend"
import "../tree"
import "../txt"

canned :: `diff --git a/a.go b/a.go
index 1..2 100644
--- a/a.go
+++ b/a.go
@@ -1,3 +1,5 @@
 package a
+
+// added is new.
+func added() {}
 func old() {}
-func gone() {}
diff --git a/b.txt b/b.txt
deleted file mode 100644
--- a/b.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-first
-+++ not a header
`

@(test)
diff_sides_reads_both_sides :: proc(t: ^testing.T) {
	added, removed := diff_sides(canned, context.temp_allocator)
	testing.expect_value(t, len(added), 1)
	a := added["a.go"]
	testing.expect_value(t, len(a), 3)
	testing.expect_value(t, a[0].line, 2)
	testing.expect_value(t, a[1].line, 3)
	testing.expect_value(t, a[1].text, "// added is new.")
	testing.expect_value(t, a[2].line, 4)
	testing.expect_value(t, len(removed["a.go"]), 1)
	testing.expect_value(t, removed["a.go"][0], "func gone() {}")
	testing.expect_value(t, len(removed["b.txt"]), 2)
	testing.expect_value(t, removed["b.txt"][1], "+++ not a header")
	testing.expect_value(t, hunk_start("@@ -10,7 +12 @@ func x") or_else -1, 12)
}

// new_repo makes a repository with two commits: a.go first, then a
// function, a test and a comment added to it.
new_repo :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	scratch, err := os.make_directory_temp(temp, "review-change-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "no scratch directory")
	}
	root = scratch
	git := proc(root: string, args: ..string) -> bool {
		argv := make([dynamic]string, context.temp_allocator)
		append(
			&argv,
			"git",
			"-c",
			"user.email=t@t",
			"-c",
			"user.name=t",
			"-c",
			"commit.gpgsign=false",
		)
		append(&argv, ..args)
		return sh.exec(argv[:], {dir = root}, context.temp_allocator).ok
	}
	write := proc(root, name, src: string) -> bool {
		path := filepath.join({root, name}, context.temp_allocator) or_else name
		return os.write_entire_file(path, transmute([]byte)src) == nil
	}
	ok = git(root, "init", "-q")
	ok &&= write(root, "a.go", "package a\n\nfunc old() {}\n")
	ok &&= git(root, "add", "a.go")
	ok &&= git(root, "commit", "-q", "-m", "a: begin")
	ok &&= write(
		root,
		"a.go",
		"package a\n\nimport \"fmt\"\n\nfunc old() {}\n\n// added is new.\nfunc added() {}\n",
	)
	ok &&= write(
		root,
		"a_test.go",
		"package a\n\nimport \"testing\"\n\nfunc TestAdded(t *testing.T) {\n\tadded()\n}\n",
	)
	ok &&= git(root, "add", "a.go", "a_test.go")
	ok &&= git(root, "commit", "-q", "-m", "a: add added")
	return root, ok
}

@(test)
gather_reads_a_range_through_the_sidecar :: proc(t: ^testing.T) {
	if !frontend.installed(.Go) {
		testing.fail_now(t, "review-go is not on the path")
	}
	root, made := new_repo(t)
	testing.expect(t, made, "the fixture repository")
	defer os.remove_all(root)

	c, ok := gather("HEAD^..HEAD", root, context.temp_allocator)
	testing.expect(t, ok, "gather")
	testing.expect_value(t, len(c.files), 2)
	testing.expect_value(t, strings.trim_space(c.message), "a: add added")
	testing.expect_value(t, c.truncated, false)

	tr, at_ok := tree.at(root, "HEAD^..HEAD", context.temp_allocator)
	testing.expect(t, at_ok, "materialise")
	defer tree.close(tr)
	testing.expect(t, tr.dir != root, "a range is read from scratch")
	testing.expect(t, tree.exists(tr, "a_test.go"))

	testing.expect(t, read(&c, tr, context.temp_allocator), "read")
	testing.expect_value(t, len(c.uncovered), 0)
	testing.expect_value(t, len(c.symbols), 1)
	testing.expect_value(t, c.symbols[0].name, "added")
	testing.expect_value(t, c.symbols[0].kind, "func")
	testing.expect_value(t, c.symbols[0].doc, "added is new.")
	testing.expect_value(t, c.symbols[0].body, "func added() {}")
	testing.expect_value(t, c.symbols[0].pkg, "a")
	testing.expect_value(t, len(c.tests), 1)
	testing.expect_value(t, c.tests[0].name, "TestAdded")
	testing.expect_value(t, c.tests[0].body, "func TestAdded(t *testing.T) {\n\tadded()\n}")
	testing.expect_value(t, len(c.comments), 1)
	testing.expect_value(t, c.comments[0].text, "added is new.")
	testing.expect_value(t, len(c.imports["a.go"]), 1)
	testing.expect_value(t, c.imports["a.go"][0], "fmt")

	declared, indexed := index(tr, context.temp_allocator)
	testing.expect(t, indexed, "index")
	names := make([dynamic]string, context.temp_allocator)
	for d in declared {
		append(&names, d.name)
	}
	testing.expect_value(t, fmt.tprint(names[:]), `["old", "added"]`)
}

@(test)
comments_are_read_beside_their_code :: proc(t: ^testing.T) {
	lines := []string {
		"package x",
		"",
		"// above",
		"// and more",
		"",
		"func f() {",
		"\treturn",
		"}",
	}
	testing.expect_value(t, code_below(lines, 3, context.temp_allocator), "func f() {\nreturn")
	testing.expect_value(t, code_below(lines, 8, context.temp_allocator), "")
	testing.expect_value(
		t,
		skip_line(
			Function{line = 10, body = "func TestX(t *testing.T) {\n\tt.Skip(\"later\")\n}"},
		),
		11,
	)
	testing.expect_value(
		t,
		skip_line(Function{line = 10, body = "func TestX(t *testing.T) {}"}),
		0,
	)
	testing.expect_value(t, count_numstat("3\t1\ta.go\n-\t-\tb.png\n2\t0\tc.go\n"), 6)
}

@(test)
heuristic_reads_comments_by_shape :: proc(t: ^testing.T) {
	src := "#!/usr/bin/env python\n# one\nx = 1  # not a comment line\n\"\"\"\n# two\n/* three\n * four */\n"
	touched := make([dynamic]Diff_Line, context.temp_allocator)
	for line in ([]int{1, 2, 3, 5, 6, 7}) {
		append(&touched, Diff_Line{line, ""})
	}
	got := comment_prose(transmute([]byte)src, "a.py", touched, context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	for l in got {
		append(&texts, l.text)
	}
	testing.expect_value(t, fmt.tprint(texts[:]), `["one", "two", "three", "four"]`)
	testing.expect(t, heuristic_covers("a.zig"))
	testing.expect(t, !heuristic_covers("a.md"))
}

@(test)
temporal_counts_the_pair :: proc(t: ^testing.T) {
	root, made := new_repo(t)
	testing.expect(t, made, "the fixture repository")
	defer os.remove_all(root)
	git := proc(root: string, args: ..string) -> bool {
		argv := make([dynamic]string, context.temp_allocator)
		append(
			&argv,
			"git",
			"-c",
			"user.email=t@t",
			"-c",
			"user.name=t",
			"-c",
			"commit.gpgsign=false",
		)
		append(&argv, ..args)
		return sh.exec(argv[:], {dir = root}, context.temp_allocator).ok
	}
	for i in 0 ..< 8 {
		a := filepath.join({root, "pair_a.go"}, context.temp_allocator) or_else ""
		b := filepath.join({root, "pair_b.go"}, context.temp_allocator) or_else ""
		testing.expect(
			t,
			os.write_entire_file(
				a,
				transmute([]byte)fmt.tprintf("package a\n\nvar v%d = %d\n", i, i),
			) ==
			nil,
		)
		testing.expect(
			t,
			os.write_entire_file(
				b,
				transmute([]byte)fmt.tprintf("package b\n\nvar w%d = %d\n", i, i),
			) ==
			nil,
		)
		testing.expect(t, git(root, "add", "pair_a.go", "pair_b.go"))
		testing.expect(t, git(root, "commit", "-q", "-m", fmt.tprintf("grow: round %d", i)))
	}
	a := filepath.join({root, "pair_a.go"}, context.temp_allocator) or_else ""
	testing.expect(
		t,
		os.write_entire_file(a, transmute([]byte)string("package a\n\nvar v9 = 9\n")) == nil,
	)
	testing.expect(t, git(root, "add", "pair_a.go"))
	c, ok := gather("", root, context.temp_allocator)
	testing.expect(t, ok)
	temporal, counted := c.temporal.?
	testing.expect(t, counted, "history counted")
	testing.expect_value(t, temporal.commits["pair_a.go"], 8)
	testing.expect_value(t, len(temporal.partners["pair_a.go"]), 1)
	testing.expect_value(t, temporal.partners["pair_a.go"][0].name, "pair_b.go")
	testing.expect_value(t, temporal.partners["pair_a.go"][0].shared, 8)
	testing.expect(t, c.changed > 0)
	testing.expect(t, len(c.history) >= 10)
}

@(test)
a_message_file_loses_its_template :: proc(t: ^testing.T) {
	temp := os.temp_directory(context.temp_allocator) or_else ""
	path := filepath.join({temp, "review_message_fixture.txt"}, context.temp_allocator) or_else ""
	testing.expect(
		t,
		os.write_entire_file(
			path,
			transmute([]byte)string(
				"x: do it\n\n# Please enter the commit message\n# Lines starting with '#' are ignored\nbecause it matters\n",
			),
		) ==
		nil,
	)
	defer os.remove(path)
	message, ok := read_message(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, message, "x: do it\n\nbecause it matters")
	_, missing := read_message("/nowhere/at/all", context.temp_allocator)
	testing.expect(t, !missing)
}

@(test)
code_files_are_the_ones_a_reader_could_exist_for :: proc(t: ^testing.T) {
	testing.expect(t, is_code_file("a/b.zig"))
	testing.expect(t, is_code_file("Justfile"))
	testing.expect(t, !is_code_file("readme.md"))
	testing.expect(t, !is_code_file("go.sum"))
	testing.expect(t, !is_code_file("x/.gitignore"))
	testing.expect(t, !is_code_file("Dockerfile"))
}

@(test)
gather_of_nothing_staged_is_empty :: proc(t: ^testing.T) {
	root, made := new_repo(t)
	testing.expect(t, made, "the fixture repository")
	defer os.remove_all(root)
	c, ok := gather("", root, context.temp_allocator)
	testing.expect(t, ok, "gather")
	testing.expect_value(t, len(c.files), 0)
	testing.expect_value(t, c.diff, "")
	testing.expect_value(t, c.message, "")
}

@(test)
candidates_rank_by_shared_words :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := Change{}
	c.symbols = make([dynamic]Symbol, context.temp_allocator)
	append(
		&c.symbols,
		Symbol {
			name = "IconEntrySize",
			kind = "value",
			file = "b.go",
			line = 9,
			signature = "const IconEntrySize = 16",
		},
	)
	c.index = []Declared {
		{
			name = "EntrySize",
			kind = "value",
			file = "a.go",
			line = 3,
			text = "const EntrySize = 16",
		},
		{
			name = "iconCount",
			kind = "func",
			file = "a.go",
			line = 8,
			text = "func iconCount() int {",
		},
		{
			name = "unrelated",
			kind = "value",
			file = "a.go",
			line = 1,
			text = "const unrelated = 16",
		},
		{
			name = "IconEntrySize",
			kind = "value",
			file = "b.go",
			line = 9,
			text = "const IconEntrySize = 16",
		},
	}
	find_candidates(&c, context.temp_allocator)
	twins := c.twins["IconEntrySize"]
	testing.expect_value(t, len(twins), 2)
	if len(twins) == 2 {
		testing.expect_value(t, twins[0], "a.go:3: const EntrySize = 16   <- same value")
	}
	near := c.candidates["IconEntrySize"]
	testing.expect_value(t, len(near), 4)
	if len(near) == 4 {
		testing.expect_value(t, near[2], "a.go:3: const EntrySize = 16")
		testing.expect_value(t, near[3], "a.go:8: func iconCount() int {")
	}
	testing.expect(t, same("x = 3", "y  = 3 "))
	testing.expect(t, same("A :: 3", "B = 3"))
	testing.expect(t, !same("f()", "g()"))
	testing.expect_value(
		t,
		fmt.tprint(txt.split_words("icoEntry_size")),
		`["ico", "Entry", "size"]`,
	)
}

@(test)
settles_the_shell_dialect :: proc(t: ^testing.T) {
	Case :: struct {
		path, first_line, shell: string,
	}
	for c in ([]Case {
			// An extension answers for itself, and the first line is not read.
			{"lib.sh", "", "sh"},
			{"build.bash", "", "bash"},
			{"suite.bats", "", "bats"},
			{"tools/run.ksh", "", "ksh"},
			{".bashrc", "", "bash"},
			{".profile", "", "sh"},
			// A script named for the command it is says so in its shebang.
			{"bin/deploy", "#!/usr/bin/env bash", "bash"},
			{"bin/deploy", "#!/bin/bash -eu", "bash"},
			{"bin/deploy", "#!/usr/bin/env -S bash -eu", "bash"},
			{"configure", "#!/bin/sh", "sh"},
			{"bin/old", "#!/bin/dash", "sh"},
			{"bin/korn", "#!/usr/bin/ksh93", "ksh"},
			// Not a shell, however it is spelled.
			{"bin/tool", "#!/usr/bin/env python3", ""},
			{"bin/tool", "#!/usr/bin/env zsh", ""},
			{"bin/tool", "#!/usr/bin/env fish", ""},
			{"bin/tool", "", ""},
			{"notes.md", "#!/bin/bash", ""},
			{"theme.zsh", "", ""},
			{"main.go", "", ""},
		}) {
		testing.expectf(
			t,
			shell_of(c.path, c.first_line) == c.shell,
			"%s (%s): %s",
			c.path,
			c.first_line,
			shell_of(c.path, c.first_line),
		)
	}
	// Only a name that answers nothing is worth opening the file for.
	testing.expect(t, needs_shebang("bin/deploy"))
	testing.expect(t, !needs_shebang("lib.sh"))
	testing.expect(t, !needs_shebang(".bashrc"))
	// A file no reader could exist for is never opened to ask.
	testing.expect(t, !needs_shebang("Makefile"))
	testing.expect(t, !needs_shebang("LICENSE"))
	testing.expect(t, heuristic_covers("bin/deploy", "bash"))
	testing.expect(t, !heuristic_covers("bin/deploy", ""))
}

@(test)
keeps_the_indent_a_comment_marker_hides :: proc(t: ^testing.T) {
	// The margin is what tells a shown example from code left behind, and
	// it is only visible before the marker is stripped.
	src := "package p\n// open opens it. A use:\n//\n//\tdb := open(path)\n//   spaced := 1\n#\tshell := 1\n/*\n *     starred := 1\n */\n"
	touched := make([dynamic]Diff_Line, context.temp_allocator)
	for line in ([]int{1, 2, 3, 4, 5, 6, 7, 8, 9}) {
		append(&touched, Diff_Line{line, ""})
	}
	got := comment_prose(transmute([]byte)src, "a.odin", touched, context.temp_allocator)
	by := make(map[int]Located, context.temp_allocator)
	for c in got {
		by[c.line] = c
	}
	testing.expect_value(t, by[2].indent, 1)
	testing.expect_value(t, by[4].indent, 4)
	testing.expect_value(t, by[4].text, "db := open(path)")
	testing.expect_value(t, by[5].indent, 3)
	testing.expect_value(t, by[6].indent, 4)
	// A starred block comment's margin counts the star: one space, the
	// star, then five, so the text stands seven columns in.
	testing.expect_value(t, by[8].indent, 7)
	testing.expect_value(t, by[8].text, "starred := 1")
	// What matters is only that an example stands further in than the
	// prose it is shown under, in either comment habit.
	testing.expect(t, by[4].indent > by[2].indent)
	testing.expect_value(t, block_indent("\tcode"), 4)
	testing.expect_value(t, block_indent("prose"), 0)
	testing.expect_value(t, block_indent(" * prose"), 3)
	// A tab stands for four columns so the two habits compare.
	testing.expect_value(t, indent_of("\tx"), 4)
	testing.expect_value(t, indent_of("  x"), 2)
	testing.expect_value(t, indent_of("x"), 0)
}
