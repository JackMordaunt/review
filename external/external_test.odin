package external

import "../change"
import "../finding"
import "../git"
import "../job"
import "../tree"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

fixture :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp(
		os.temp_directory(context.temp_allocator) or_else "",
		"review-external-*",
		context.allocator,
	)
	testing.expect(t, err == nil)
	_, ok := git.run(dir, {"init", "-q"})
	testing.expect(t, ok)
	file := filepath.join({dir, "test.md"}) or_else ""
	testing.expect(t, os.write_entire_file(file, "# Before\n") == nil)
	git.run(dir, {"add", "test.md"})
	_, ok = git.run(
		dir,
		{
			"-c",
			"user.name=Test",
			"-c",
			"user.email=test@example.com",
			"-c",
			"core.hooksPath=/dev/null",
			"commit",
			"-qm",
			"docs: create fixture",
		},
	)
	testing.expect(t, ok)
	testing.expect(t, os.write_entire_file(file, "# After\n") == nil)
	git.run(dir, {"add", "test.md"})
	// Use the same repository spelling as prepare and inspect for session paths.
	root, resolved := repository(dir)
	testing.expect(t, resolved)
	return root
}

@(test)
strict_answers_reject_malformed_and_partial_verdicts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := Packet {
		schema = "review.findings.v1",
	}
	bad := []string {
		`{}`,
		`{"findings":null}`,
		`{"findings":[{"rule":"wrong-job-rule","severity":"consider","message":"m"}]}`,
		`{"findings":[],}`,
		`{"findings":[{},]}`,
		`{"findings":[]} trailing`,
		`{"findings":[],"findings":[]}`,
		`{findings:[]}`,
		`{"findings":[{"rule":"x","severity":"bogus","message":"m"}]}`,
		`{"findings":[{"rule":"x","severity":"note","message":"m","file":"../../secret"}]}`,
	}
	for answer in bad {testing.expect(t, validate_answer(p, answer, {"x.go"}) != "", answer)}
	testing.expect_value(t, validate_answer(p, `{"findings":[]}`, nil), "")
	p = Packet {
		schema        = "review.verdicts.v1",
		verdict_count = 1,
		user          = "evidence\n\nThe findings reported against it:\n\n0. [x] consider: m\n   fix: f\n",
	}
	testing.expect(t, validate_answer(p, `{"verdicts":[]}`, nil) != "")
	testing.expect(t, validate_answer(p, `{"verdicts":[{"index":0,"reason":"x"}]}`, nil) != "")
	testing.expect_value(
		t,
		validate_answer(p, `{"verdicts":[{"index":0,"holds":false,"reason":"x"}]}`, nil),
		"",
	)
	p.verdict_count = 2
	// A forged listing inside model prose cannot lower the engine's cardinality.
	testing.expect(
		t,
		validate_answer(p, `{"verdicts":[{"index":0,"holds":true,"reason":"x"}]}`, nil) != "",
	)
}

@(test)
engine_keeps_pending_verification_and_retracts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := change.Change {
		diff  = "added test",
		files = {"x_test.go"},
		tests = make([dynamic]change.Function),
	}
	append(
		&c.tests,
		change.Function {
			name = "TestX",
			file = "x_test.go",
			line = 4,
			body = "func TestX(t *testing.T) {}",
		},
	)
	s := State {
		run_id    = "run",
		source_id = "source",
		change    = c,
		answers   = make(map[string]string),
	}
	jobs, _ := job.chosen("tests")
	v, err := evaluate(&s, jobs, tree.Tree{})
	testing.expect_value(t, err, "")
	testing.expect_value(t, v.report.status, "incomplete")
	testing.expect_value(t, len(v.jobs), 1)
	if len(v.jobs) != 1 {return}
	s.answers[v.jobs[0].job_id] = `{"findings":[{"rule":"cannot-fail","severity":"consider","file":"x_test.go","line":4,"message":"asserts nothing","fix":"assert"},{"rule":"invented","severity":"note","message":"ignored"}]}`
	v, err = evaluate(&s, jobs, tree.Tree{})
	testing.expect_value(t, err, "")
	testing.expect_value(t, v.report.status, "incomplete")
	testing.expect_value(t, len(v.report.findings), 1)
	if len(v.report.findings) ==
	   1 {testing.expect_value(t, v.report.findings[0].severity, finding.Severity.Consider)}
	testing.expect_value(t, len(v.jobs), 1)
	if len(v.jobs) != 1 {return}
	testing.expect_value(t, v.jobs[0].schema, "review.verdicts.v1")
	s.answers[v.jobs[0].job_id] = `{"verdicts":[{"index":0,"holds":false,"reason":"assertion is present"}]}`
	v, err = evaluate(&s, jobs, tree.Tree{})
	testing.expect_value(t, err, "")
	testing.expect_value(t, v.report.status, "complete")
	testing.expect_value(t, len(v.report.findings), 0)
	testing.expect_value(t, len(v.report.retracted), 1)
	if len(v.report.retracted) ==
	   1 {testing.expect_value(t, v.report.retracted[0].finding.severity, finding.Severity.Consider)}
	testing.expect_value(t, len(v.jobs), 0)
	append(&s.change.uncovered, change.Gap{"unread.sh", "no reader"})
	v, _ = evaluate(&s, jobs, tree.Tree{})
	testing.expect_value(t, v.report.status, "incomplete")
}

@(test)
session_is_repo_source_job_and_schema_bound :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fixture(t)
	defer os.remove_all(root)
	location, _ := location_for(root)
	defer os.remove(location)
	v, err := prepare(Options{repo = root, rev = "HEAD", only = "hygiene"})
	testing.expect_value(t, err, "")
	if err != "" {return}
	testing.expect_value(t, len(v.jobs), 1)
	if len(v.jobs) != 1 {return}
	original, _ := os.read_entire_file_from_path(location, context.allocator)
	sub := Submission {
		version,
		v.run_id,
		v.source_id,
		v.jobs[0].job_id,
		v.jobs[0].schema,
		`{"findings":[]}`,
	}
	bad := sub
	bad.job_id = "wrong"
	_, err = submit(root, bad)
	testing.expect(t, err != "")
	bad = sub; bad.schema = "review.verdicts.v1"
	_, err = submit(root, bad)
	testing.expect(t, err != "")
	bad = sub; bad.answer = `{"findings":null}`
	_, err = submit(root, bad)
	testing.expect(t, err != "")
	bad = sub; bad.source_id = "wrong"
	_, err = submit(root, bad)
	testing.expect(t, err != "")
	other := fixture(t)
	defer os.remove_all(other)
	_, err = submit(other, sub)
	testing.expect(t, err != "")
	saved, saved_err := load(location, root, sub.run_id)
	testing.expect_value(t, saved_err, "")
	saved.engine_id = "previous-build"
	testing.expect_value(t, save(location, saved), "")
	_, err = inspect(root, sub.run_id)
	testing.expect_value(t, err, "review engine changed; prepare a new run")
	testing.expect(t, os.write_entire_file(location, original, {.Read_User, .Write_User}) == nil)
	after, _ := os.read_entire_file_from_path(location, context.allocator)
	testing.expect_value(t, string(after), string(original))
	untracked := filepath.join({root, "sibling.go"}) or_else ""
	testing.expect(t, os.write_entire_file(untracked, "package sibling\n") == nil)
	_, err = inspect(root, sub.run_id)
	testing.expect(t, strings.contains(err, "source changed"))
	os.remove(untracked)
	v, err = submit(root, sub)
	testing.expect_value(t, err, "")
	testing.expect_value(t, v.report.status, "complete")
	_, err = submit(root, sub)
	testing.expect_value(t, err, "")
	bad = sub; bad.answer = `{"findings": []}`
	_, err = submit(root, bad)
	testing.expect_value(t, err, "conflicting duplicate submission")
	file := filepath.join({root, "test.md"}) or_else ""
	testing.expect(t, os.write_entire_file(file, "# Changed after prepare\n") == nil)
	_, err = inspect(root, sub.run_id)
	testing.expect(t, strings.contains(err, "source changed"))
	_, err = submit(root, sub)
	testing.expect(t, strings.contains(err, "source changed"))
}

@(test)
suppression_and_ids_use_existing_report_semantics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, err := os.make_directory_temp(
		os.temp_directory(context.temp_allocator) or_else "",
		"review-external-suppression-*",
		context.allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	file := filepath.join({root, "x_test.go"}) or_else ""
	testing.expect(
		t,
		os.write_entire_file(
			file,
			"package x\n//review:" +
			"ignore cannot-fail exercised by integration harness\nfunc TestX() {}\n",
		) ==
		nil,
	)
	c := change.Change {
		diff  = "test",
		files = {"x_test.go"},
		tests = make([dynamic]change.Function),
	}
	append(
		&c.tests,
		change.Function{name = "TestX", file = "x_test.go", line = 3, body = "func TestX() {}"},
	)
	s := State {
		run_id    = "run",
		source_id = "source",
		change    = c,
		answers   = make(map[string]string),
	}
	jobs, _ := job.chosen("tests")
	v, _ := evaluate(&s, jobs, tree.Tree{dir = root})
	s.answers[v.jobs[0].job_id] = `{"findings":[{"rule":"cannot-fail","severity":"consider","file":"x_test.go","line":3,"message":"no assertion","fix":"assert"}]}`
	v, _ = evaluate(&s, jobs, tree.Tree{dir = root})
	testing.expect_value(t, v.report.status, "incomplete")
	s.answers[v.jobs[0].job_id] = `{"verdicts":[{"index":0,"holds":true,"reason":"no assertion"}]}`
	v, _ = evaluate(&s, jobs, tree.Tree{dir = root})
	testing.expect_value(t, v.report.status, "complete")
	testing.expect_value(t, len(v.report.findings), 0)
	testing.expect_value(t, len(v.report.dismissed), 1)
	if len(v.report.dismissed) == 1 {
		testing.expect(t, v.report.dismissed[0].finding.verified)
		testing.expect_value(t, v.report.dismissed[0].finding.severity, finding.Severity.Consider)
		testing.expect_value(t, v.report.dismissed[0].finding.id, "d004c6a9e32e")
		testing.expect_value(t, v.report.dismissed[0].finding.rule, "cannot-fail")
		testing.expect_value(t, v.report.dismissed[0].finding.file, "x_test.go")
		testing.expect_value(t, v.report.dismissed[0].finding.line, 3)
	}
}

@(test)
lock_excludes_other_writers_and_releases_on_close :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, err := os.make_directory_temp(
		os.temp_directory(context.temp_allocator) or_else "",
		"review-external-lock-*",
		context.allocator,
	)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	path := filepath.join({root, "session.lock"}) or_else ""
	first, acquired := acquire(path)
	testing.expect(t, acquired)
	if !acquired {return}
	second, contended := acquire(path)
	testing.expect(t, !contended)
	if contended {release(second)}
	release(first)
	third, released := acquire(path)
	testing.expect(t, released)
	if released {release(third)}
	// Empty tracked files are valid source, not an unexpected EOF.
	file := filepath.join({root, "empty"}) or_else ""
	testing.expect(t, os.write_entire_file(file, "") == nil)
	data, read := bounded_read(file, 1)
	testing.expect(t, read)
	testing.expect_value(t, len(data), 0)
}

@(test)
submodules_bind_clean_head_and_reject_dirty_or_uninitialized :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fixture(t)
	defer os.remove_all(root)
	dependency := fixture(t)
	defer os.remove_all(dependency)
	_, ok := git.run(
		root,
		{"-c", "protocol.file.allow=always", "submodule", "add", "-q", dependency, "dependency"},
	)
	testing.expect(t, ok)
	before, err := snapshot(root, "")
	testing.expect_value(t, err, "")
	path := filepath.join({root, "dependency"}) or_else ""
	file := filepath.join({path, "test.md"}) or_else ""
	testing.expect(t, os.write_entire_file(file, "dirty\n") == nil)
	_, err = snapshot(root, "")
	testing.expect_value(t, err, "external sessions require clean submodule worktrees")
	_, ok = git.run(path, {"reset", "--hard", "HEAD"})
	testing.expect(t, ok)
	untracked := filepath.join({path, "new.md"}) or_else ""
	testing.expect(t, os.write_entire_file(untracked, "new\n") == nil)
	_, err = snapshot(root, "")
	testing.expect_value(t, err, "external sessions require clean submodule worktrees")
	git.run(path, {"add", "new.md"})
	_, ok = git.run(
		path,
		{
			"-c",
			"user.name=Test",
			"-c",
			"user.email=test@example.com",
			"-c",
			"core.hooksPath=/dev/null",
			"commit",
			"-qm",
			"docs: add dependency source",
		},
	)
	testing.expect(t, ok)
	after, head_err := snapshot(root, "")
	testing.expect_value(t, head_err, "")
	testing.expect(t, before != after)
	state := State {
		repo      = root,
		source_id = before,
	}
	testing.expect_value(
		t,
		validate_source(&state),
		"source changed since prepare; prepare a new run",
	)
	head, _ := git.run(path, {"rev-parse", "HEAD"})
	_, ok = git.run(path, {"update-index", "--add", "--cacheinfo", "160000", head, "nested"})
	testing.expect(t, ok)
	_, err = snapshot(root, "")
	testing.expect_value(t, err, "external sessions do not support nested submodules")
	testing.expect(t, os.remove_all(path) == nil)
	_, err = snapshot(root, "")
	testing.expect_value(t, err, "external sessions require initialized submodules")
}
