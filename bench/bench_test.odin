package bench

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "jm:sh"
import "jm:sqlite3"

@(test)
bench_counts_what_fires :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root, err := os.make_directory_temp(temp, "review-bench-*", context.temp_allocator)
	testing.expect(t, err == nil)
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
	write := proc(root, name, src: string) -> bool {
		path := filepath.join({root, name}, context.temp_allocator) or_else name
		return os.write_entire_file(path, transmute([]byte)src) == nil
	}
	testing.expect(t, git(root, "init", "-q"))
	testing.expect(t, write(root, "x.go", "package x\n"))
	testing.expect(t, git(root, "add", "x.go"))
	testing.expect(t, git(root, "commit", "-q", "-m", "x: begin"))
	testing.expect(t, write(root, "x.go", "package x\n\nvar a = 1\n"))
	testing.expect(t, git(root, "add", "x.go"))
	testing.expect(t, git(root, "commit", "-q", "-m", "whoops"))
	testing.expect(t, write(root, "x.go", "package x\n\nvar a = 1\nvar b = 2\n"))
	testing.expect(t, git(root, "add", "x.go"))
	testing.expect(t, git(root, "commit", "-q", "-m", "x: add b"))

	out, run_err := run(root, Options{n = 10, db = "off"}, nil)
	testing.expect_value(t, run_err, "")
	testing.expect(t, strings.contains(out, "2 commits measured"), out)
	testing.expect(t, strings.contains(out, "message-frustration"), out)
	listed, _ := run(root, Options{n = 10, rule = "message-frustration", db = "off"}, nil)
	testing.expect(t, strings.contains(listed, "whoops"), listed)
	testing.expect(
		t,
		strings.contains(listed, "message-frustration fired on 1 of 2 commits"),
		listed,
	)
	_, none := run(root, Options{n = 10, author = "nobody-here", db = "off"}, nil)
	testing.expect_value(t, none, "no commits to measure")
}

// A memo is only worth having if the second run says exactly what the
// first did. This builds a repository, measures it into a memo of its own,
// then measures it again and compares the reports byte for byte, and proves
// the second run replayed rather than re-measured by planting a rule in the
// memo that no check could ever produce.
@(test)
bench_replays_what_it_measured :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	temp := os.temp_directory(context.temp_allocator) or_else ""
	root, err := os.make_directory_temp(temp, "review-bench-memo-*", context.temp_allocator)
	testing.expect(t, err == nil)
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
	write := proc(root, name, src: string) -> bool {
		path := filepath.join({root, name}, context.temp_allocator) or_else name
		return os.write_entire_file(path, transmute([]byte)src) == nil
	}
	testing.expect(t, git(root, "init", "-q"))
	testing.expect(t, write(root, "x.go", "package x\n"))
	testing.expect(t, git(root, "add", "x.go"))
	testing.expect(t, git(root, "commit", "-q", "-m", "x: begin"))
	testing.expect(t, write(root, "x.go", "package x\n\nvar a = 1\n"))
	testing.expect(t, git(root, "add", "x.go"))
	testing.expect(t, git(root, "commit", "-q", "-m", "whoops"))

	db := filepath.join({root, "memo.db"}, context.temp_allocator) or_else ""
	first, first_err := run(root, Options{n = 10, db = db}, nil)
	testing.expect_value(t, first_err, "")
	testing.expect(t, strings.contains(first, "message-frustration"), first)

	second, second_err := run(root, Options{n = 10, db = db}, nil)
	testing.expect_value(t, second_err, "")
	testing.expect_value(t, second, first)

	// Equality alone would hold even if the memo never stored anything,
	// because measuring is deterministic. So plant a rule no check can
	// produce and require the next run to report it: only a replay can.
	memo := store_open(db)
	testing.expect(t, memo.ready)
	testing.expect(
		t,
		sqlite3.exec(
			memo.db,
			`INSERT OR REPLACE INTO fire(sha, version, rule, message)
			 SELECT sha, version, 'planted-by-the-test', 'planted' FROM measured WHERE ok = 1`,
		) ==
		nil,
	)
	store_close(&memo)

	replayed, replay_err := run(root, Options{n = 10, db = db}, nil)
	testing.expect_value(t, replay_err, "")
	testing.expect(t, strings.contains(replayed, "planted-by-the-test"), replayed)

	// --fresh must ignore the memo: the planted rule cannot survive a
	// measurement, and what it reports must match the first run.
	fresh, fresh_err := run(root, Options{n = 10, db = db, fresh = true}, nil)
	testing.expect_value(t, fresh_err, "")
	testing.expect(t, !strings.contains(fresh, "planted-by-the-test"), fresh)
	testing.expect_value(t, fresh, first)

	// "off" is a memo that was never opened: still correct, never consulted.
	off, off_err := run(root, Options{n = 10, db = "off"}, nil)
	testing.expect_value(t, off_err, "")
	testing.expect(t, !strings.contains(off, "planted-by-the-test"), off)
	testing.expect_value(t, off, first)
}
