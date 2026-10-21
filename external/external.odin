// Package external lends the existing review engine to a calling assistant.
// One bounded, atomic session per repository lives outside the provider cache.
package external

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

import "../analyser"
import "../cache"
import "../change"
import "../check"
import "../finding"
import "../git"
import "../job"
import "../provider"
import "../report"
import "../reviewer"
import "../tree"

//review:ignore restates-a-fact external session and report contracts have independent protocol versions
version :: 1
max_state :: 8 * 1024 * 1024
max_answer :: 256 * 1024
max_prompt :: 256 * 1024
max_jobs :: 256

//review:ignore already-named external repo/rev/job selection differs from benchmark sampling options
Options :: struct {
	repo, rev, only: string,
}
Submission :: struct {
	version:                                   int,
	run_id, source_id, job_id, schema, answer: string,
}
Packet :: struct {
	job_id, schema, system, user: string,
	verdict_count:                int,
}
//review:ignore noun-for-type View is the result noun shared by prepare, submit and inspect
View :: struct {
	version:                 int,
	run_id, source_id, repo: string,
	jobs:                    []Packet,
	report:                  report.Contract,
}

@(private)
State :: struct {
	version:                                       int,
	run_id, source_id, engine_id, repo, rev, only: string,
	change:                                        change.Change,
	static:                                        []finding.Finding,
	answers:                                       map[string]string,
}
@(private)
Exchange :: struct {
	state:   ^State,
	pending: [dynamic]Packet,
	err:     string,
}

// prepare runs the ordinary readers and static checks without choosing a provider.
// Replacing a repository's previous session is deliberate: only one snapshot is active.
prepare :: proc(opts: Options, allocator := context.allocator) -> (view: View, err: string) {
	context.allocator = allocator
	root, ok := repository(opts.repo)
	if !ok {return {}, "not in a git repository"}
	jobs, job_err := job.chosen(opts.only)
	if job_err != "" {return {}, job_err}
	location, path_err := location_for(root)
	if path_err != "" {return {}, path_err}
	lock := strings.concatenate({location, ".lock"})
	held, locked := acquire(lock)
	if !locked {return {}, "external session is busy; retry after the current operation"}
	defer release(held)
	engine_id, engine_err := engine_identity()
	if engine_err != "" {return {}, engine_err}
	source, source_err := snapshot(root, opts.rev)
	if source_err != "" {return {}, source_err}
	c, gathered := change.gather(opts.rev, root)
	if !gathered {return {}, "git could not describe the revision"}
	t, materialised := tree.at(root, opts.rev)
	if !materialised {return {}, "could not materialise the revision"}
	defer tree.close(t)
	change.read(&c, t)
	c.index, _ = change.index(t)
	change.find_candidates(&c)
	static := make([dynamic]finding.Finding)
	if strings.trim_space(c.diff) != "" {
		append(&static, ..check.run(check.scope_of(&c, t)))
		_, ranged := tree.ends(opts.rev)
		append(&static, ..analyser.check(&c, t, ranged))
	}
	finding.name(static[:])
	state := State {
		version   = version,
		repo      = root,
		rev       = opts.rev,
		only      = opts.only,
		run_id    = cache.key(
			"external-run",
			source,
			fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())),
		),
		source_id = source,
		engine_id = engine_id,
		change    = c,
		static    = static[:],
		answers   = make(map[string]string),
	}
	view, err = evaluate(&state, jobs, t)
	if err != "" {return {}, err}
	if err = validate_source(&state); err != "" {return {}, err}
	if err = save(location, state); err != "" {return {}, err}
	return view, ""
}

// submit accepts exactly one answer for an exported packet. A byte-identical
// retry is idempotent; every rejection leaves the saved session untouched.
submit :: proc(
	repo: string,
	answer: Submission,
	allocator := context.allocator,
) -> (
	view: View,
	err: string,
) {
	context.allocator = allocator
	if answer.version != version {return {}, "unsupported external protocol version"}
	root, ok := repository(repo)
	if !ok {return {}, "not in a git repository"}
	location, path_err := location_for(root)
	if path_err != "" {return {}, path_err}
	lock := strings.concatenate({location, ".lock"})
	held, locked := acquire(lock)
	if !locked {return {}, "external session is busy; retry after the current operation"}
	defer release(held)
	state, load_err := load(location, root, answer.run_id)
	if load_err != "" {return {}, load_err}
	if answer.source_id != state.source_id {return {}, "source identity does not match the run"}
	if err = validate_source(&state); err != "" {return {}, err}
	t, materialised := tree.at(root, state.rev)
	if !materialised {return {}, "could not materialise the revision"}
	defer tree.close(t)
	jobs, _ := job.chosen(state.only)
	view, err = evaluate(&state, jobs, t)
	if err != "" {return {}, err}
	if previous, exists := state.answers[answer.job_id]; exists {
		if previous == answer.answer && answer.schema == schema_for_answer(previous) {
			if err = validate_source(&state); err != "" {return {}, err}
			return view, ""
		}
		return {}, "conflicting duplicate submission"
	}
	found := false
	for packet in view.jobs {
		if packet.job_id != answer.job_id {continue}
		found = true
		if packet.schema != answer.schema {return {}, "schema does not match the job"}
		if err = validate_answer(packet, answer.answer, state.change.files);
		   err != "" {return {}, err}
	}
	if !found {return {}, "unknown or unavailable job"}
	state.answers[answer.job_id] = answer.answer
	view, err = evaluate(&state, jobs, t)
	if err != "" {return {}, err}
	if err = validate_source(&state); err != "" {return {}, err}
	if err = save(location, state); err != "" {return {}, err}
	return view, ""
}

// inspect reports pending work as incomplete and never asks a provider.
inspect :: proc(
	repo, run_id: string,
	allocator := context.allocator,
) -> (
	view: View,
	err: string,
) {
	context.allocator = allocator
	root, ok := repository(repo)
	if !ok {return {}, "not in a git repository"}
	location, path_err := location_for(root)
	if path_err != "" {return {}, path_err}
	state, load_err := load(location, root, run_id)
	if load_err != "" {return {}, load_err}
	if err = validate_source(&state); err != "" {return {}, err}
	t, materialised := tree.at(root, state.rev)
	if !materialised {return {}, "could not materialise the revision"}
	defer tree.close(t)
	jobs, _ := job.chosen(state.only)
	view, err = evaluate(&state, jobs, t)
	if err == "" {err = validate_source(&state)}
	return view, err
}

@(private)
evaluate :: proc(
	state: ^State,
	jobs: []job.Job,
	t: tree.Tree,
	allocator := context.allocator,
) -> (
	View,
	string,
) {
	context.allocator = allocator
	x := Exchange {
		state   = state,
		pending = make([dynamic]Packet),
	}
	r := reviewer.Reviewer {
		name          = "external/v1",
		verify        = true,
		exchange      = exchange,
		exchange_data = &x,
	}
	result: reviewer.Result
	if strings.trim_space(state.change.diff) != "" {
		result = reviewer.run(&r, &state.change, jobs, true)
	}
	if x.err != "" {return {}, x.err}
	all := make([dynamic]finding.Finding)
	append(&all, ..result.findings[:])
	append(&all, ..state.static)
	kept, dismissed := report.filter(t.dir, all[:])
	finding.sort(kept)
	for &f in kept {
		if f.file != "" && f.line > 0 {f.snippet = tree.line(t, f.file, f.line)}
	}
	faults := make([dynamic]report.Job_Fault)
	for failure in result.failures {
		append(&faults, report.Job_Fault{"external", failure})
	}
	env := report.Contract {
		version   = report.version,
		provider  = "external/v1",
		status    = report.status_of(state.change, len(result.failures)),
		findings  = kept,
		dismissed = dismissed,
		retracted = result.retracted[:],
		failed    = faults[:],
		skipped   = result.skipped[:],
		uncovered = state.change.uncovered[:],
		truncated = state.change.truncated,
	}
	if strings.trim_space(state.change.diff) == "" {env.status = "empty"}
	// Round-trip the ordinary encoder to retain stable IDs, severity and v1 lists.
	encoded, ok := report.encode(env)
	if !ok ||
	   json.unmarshal_string(encoded, &env) != nil {return {}, "could not encode the report"}
	// Severity's enum is excluded from JSON; restore the typed API after naming.
	for &f in env.findings {f.severity = finding.parse_severity(f.severity_name)}
	for &r in env.retracted {r.finding.severity = finding.parse_severity(r.finding.severity_name)}
	for &d in env.dismissed {d.finding.severity = finding.parse_severity(d.finding.severity_name)}
	return View{version, state.run_id, state.source_id, state.repo, x.pending[:], env}, ""
}

@(private)
exchange :: proc(
	data: rawptr,
	system, user: string,
	verdict: bool,
	verdict_count: int,
	allocator: runtime.Allocator,
) -> (
	provider.Answer,
	string,
) {
	context.allocator = allocator
	x := cast(^Exchange)data
	schema := "review.findings.v1"
	if verdict {schema = "review.verdicts.v1"}
	id := cache.key(
		x.state.run_id,
		strings.concatenate({schema, fmt.tprintf("/%d/", verdict_count), system}),
		strings.concatenate({x.state.source_id, user}),
	)
	if answer, exists := x.state.answers[id]; exists {return provider.Answer{text = answer}, ""}
	if len(system) + len(user) > max_prompt || len(x.pending) >= max_jobs {
		x.err = "external job limits exceeded"
		return {}, x.err
	}
	append(
		&x.pending,
		Packet{id, schema, strings.clone(system), strings.clone(user), verdict_count},
	)
	return {}, "external answer pending"
}

@(private)
repository :: proc(repo: string, allocator := context.allocator) -> (string, bool) {
	context.allocator = allocator
	dir := repo
	if dir == "" {dir = os.get_working_directory(context.temp_allocator) or_else ""}
	return git.toplevel(dir)
}

@(private)
validate_source :: proc(state: ^State, allocator := context.allocator) -> string {
	context.allocator = allocator
	current, err := snapshot(state.repo, state.rev)
	if err != "" {return err}
	if current != state.source_id {return "source changed since prepare; prepare a new run"}
	return ""
}

// Snapshot includes HEAD, index, range endpoints, and every tracked working
// file and visible untracked file: existing readers use the working tree for staged and bare-revision reviews.
@(private)
snapshot :: proc(root, rev: string, allocator := context.allocator) -> (string, string) {
	context.allocator = allocator
	index, ok := git.raw(root, {"ls-files", "--stage", "-z"})
	if !ok {return "", "could not identify the index"}
	head, _ := git.run(root, {"rev-parse", "HEAD"})
	identity := cache.key(root, head, index)
	submodules := make(map[string]bool)
	for entry in strings.split(index, "\x00", context.temp_allocator) {
		if !strings.has_prefix(entry, "160000 ") {continue}
		separator := strings.index(entry, "\t")
		if separator < 0 {return "", "could not identify submodule path"}
		name := entry[separator + 1:]
		path := filepath.join({root, name}, context.temp_allocator) or_else ""
		marker := filepath.join({path, ".git"}, context.temp_allocator) or_else ""
		if !os.exists(marker) {return "", "external sessions require initialized submodules"}
		nested, nested_ok := git.raw(path, {"submodule", "status"})
		if !nested_ok ||
		   nested != "" {return "", "external sessions do not support nested submodules"}
		status, clean := git.raw(
			path,
			{"status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none"},
		)
		if !clean ||
		   status != "" {return "", "external sessions require clean submodule worktrees"}
		sub_head, resolved := git.run(path, {"rev-parse", "HEAD"})
		if !resolved {return "", "could not identify submodule HEAD"}
		identity = cache.key(identity, name, sub_head)
		submodules[name] = true
	}
	if rev != "" {
		description, described := git.raw(root, {"rev-parse", "--revs-only", rev})
		if !described || description == "" {return "", "invalid revision"}
		identity = cache.key(identity, rev, description)
	}
	names, listed := git.raw(
		root,
		{"ls-files", "--cached", "--others", "--exclude-standard", "-z"},
	)
	if !listed {return "", "could not list source files"}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	scratch_allocator := mem.dynamic_arena_allocator(&scratch)
	total := 0
	for name in strings.split(names, "\x00", context.temp_allocator) {
		if name == "" {continue}
		mem.dynamic_arena_free_all(&scratch)
		path := filepath.join({root, name}, scratch_allocator) or_else ""
		if !os.exists(path) {identity = cache.key(identity, name, "missing"); continue}
		if os.is_dir(path) {
			if submodules[name] {continue}
			return "", "source path unexpectedly became a directory"
		}
		data, read := bounded_read(path, max_state, scratch_allocator)
		if !read {return "", "source file unreadable or larger than 8 MiB"}
		total += len(data)
		if total > 64 * 1024 * 1024 {return "", "source exceeds 64 MiB external snapshot limit"}
		identity = cache.key(identity, name, string(data))
	}
	return identity, ""
}

@(private)
location_for :: proc(root: string, allocator := context.allocator) -> (string, string) {
	context.allocator = allocator
	base, err := os.user_cache_dir(context.temp_allocator)
	if err != nil {return "", "no user cache directory"}
	dir := filepath.join({base, "review", "external-v1"}, context.temp_allocator) or_else ""
	if !os.is_dir(dir) {
		if mkdir_err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User});
		   mkdir_err != nil &&
		   !os.is_dir(dir) {return "", "could not create external session directory"}
	}
	return filepath.join(
			{dir, strings.concatenate({cache.key("repo", root, ""), ".json"})},
		) or_else "",
		""
}

@(private)
bounded_read :: proc(path: string, limit: int, allocator := context.allocator) -> ([]byte, bool) {
	context.allocator = allocator
	f, err := os.open(path)
	if err != nil {return nil, false}
	defer os.close(f)
	size, size_err := os.file_size(f)
	if size_err != nil || size < 0 || size > i64(limit) {return nil, false}
	data := make([]byte, int(size) + 1)
	n := 0
	for n < len(data) {
		got, read_err := os.read(f, data[n:])
		n += got
		if read_err == io.Error.EOF || got == 0 {break}
		if read_err != nil {return nil, false}
	}
	if n != int(size) {return nil, false}
	return data[:n], true
}

@(private)
load :: proc(
	location, root, run_id: string,
	allocator := context.allocator,
) -> (
	state: State,
	err: string,
) {
	context.allocator = allocator
	data, read := bounded_read(location, max_state)
	if !read {return {}, "unknown run or unreadable session"}
	if json.unmarshal(data, &state) != nil {return {}, "invalid external session"}
	if state.version != version || state.repo != root || state.run_id != run_id {
		return {}, "unknown run for this repository"
	}
	engine_id, engine_err := engine_identity()
	if engine_err != "" {return {}, engine_err}
	if state.engine_id != engine_id {return {}, "review engine changed; prepare a new run"}
	for &f in state.static {f.severity = finding.parse_severity(f.severity_name)}
	return state, ""
}

@(private)
save :: proc(location: string, state: State, allocator := context.allocator) -> string {
	context.allocator = allocator
	data, err := json.marshal(state)
	if err != nil || len(data) > max_state {return "external session exceeds 8 MiB limit"}
	temp := strings.concatenate({location, ".tmp"})
	if os.write_entire_file(temp, data, {.Read_User, .Write_User}) !=
	   nil {return "could not write external session"}
	defer os.remove(temp)
	if os.rename(temp, location) != nil {return "could not replace external session"}
	return ""
}

@(private)
engine_lock: sync.Mutex
@(private)
engine_digest: [64]byte
@(private)
engine_captured: bool

// capture_engine freezes this process's identity. Long-lived hosts call it at startup,
// before accepting work, so an executable replaced on disk cannot relabel old rules.
capture_engine :: proc(allocator := context.allocator) -> string {
	context.allocator = allocator
	sync.mutex_lock(&engine_lock)
	defer sync.mutex_unlock(&engine_lock)
	if engine_captured {return ""}
	digest, err := fingerprint_engine(allocator)
	if err != "" {return err}
	copy(engine_digest[:], transmute([]byte)digest)
	engine_captured = true
	return ""
}

@(private)
engine_identity :: proc(allocator := context.allocator) -> (string, string) {
	if err := capture_engine(allocator); err != "" {return "", err}
	return strings.clone(string(engine_digest[:]), allocator), ""
}

// Fingerprint the binary, including its embedded rules, even in dirty/unknown builds.
@(private)
fingerprint_engine :: proc(allocator := context.allocator) -> (string, string) {
	context.allocator = allocator
	path, path_err := os.get_executable_path(context.temp_allocator)
	if path_err != nil {return "", "could not identify the review executable"}
	when ODIN_OS == .Linux {path = "/proc/self/exe"}
	f, open_err := os.open(path)
	if open_err != nil {return "", "could not read the review executable"}
	defer os.close(f)
	hash: sha2.Context_256
	sha2.init_256(&hash)
	buffer := make([]byte, 64 * 1024, context.temp_allocator)
	total := 0
	for {
		n, read_err := os.read(f, buffer)
		total += n
		if total >
		   128 * 1024 * 1024 {return "", "review executable exceeds 128 MiB identity limit"}
		if n > 0 {sha2.update(&hash, buffer[:n])}
		if read_err != nil &&
		   read_err != io.Error.EOF {return "", "could not fingerprint the review executable"}
		if read_err == io.Error.EOF || n == 0 {break}
	}
	digest: [32]byte
	sha2.final(&hash, digest[:])
	return string(hex.encode(digest[:], allocator)), ""
}
