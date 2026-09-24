package bench

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "jm:sh"

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

	out, run_err := run(root, Options{n = 10}, nil)
	testing.expect_value(t, run_err, "")
	testing.expect(t, strings.contains(out, "2 commits measured"), out)
	testing.expect(t, strings.contains(out, "message-frustration"), out)
	listed, _ := run(root, Options{n = 10, rule = "message-frustration"}, nil)
	testing.expect(t, strings.contains(listed, "whoops"), listed)
	testing.expect(
		t,
		strings.contains(listed, "message-frustration fired on 1 of 2 commits"),
		listed,
	)
	_, none := run(root, Options{n = 10, author = "nobody-here"}, nil)
	testing.expect_value(t, none, "no commits to measure")
}
