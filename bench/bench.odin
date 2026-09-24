/*
Package bench measures the deterministic checks over as much history as
there is: run them over the last N commits and count what fires. A rule
that fires on a tenth of ordinary commits is not measuring what it claims
to.
*/
package bench

import "core:fmt"
import "core:slice"
import "core:strings"

import "../change"
import "../check"
import "../git"
import "../tree"

// Options are what a bench is narrowed to: how many commits, whose, and
// which rule to list the commits of.
Options :: struct {
	n:      int,
	author: string,
	rule:   string,
	// db is where the memo lives: empty for the default beside the answer
	// cache, "off" to disable it. A test that must measure every time sets
	// its own path rather than touching the user's.
	db:     string,
	// fresh measures every commit again instead of replaying the memo.
	fresh:  bool,
}

// Fire is one commit a rule fired on.
Fire :: struct {
	commit, subject, message: string,
}

// run measures the checks over the repository's recent commits and
// reports the fire rate per rule, or the commits one rule fired on.
// progress is told how far along the measuring is.
run :: proc(
	root: string,
	opts: Options,
	progress: proc(done, total: int),
	allocator := context.allocator,
) -> (
	out: string,
	err: string,
) {
	context.allocator = allocator
	listing := make([dynamic]string, context.temp_allocator)
	append(&listing, "rev-list", "--no-merges", fmt.tprintf("-%d", opts.n))
	if opts.author != "" {
		append(&listing, strings.concatenate({"--author=", opts.author}, context.temp_allocator))
	}
	append(&listing, "HEAD")
	commits, listed := git.lines(root, listing[:], context.temp_allocator)
	if !listed || len(commits) == 0 {
		return "", "no commits to measure"
	}
	store := store_open(opts.db)
	defer store_close(&store)
	store_begin(store)
	defer store_commit(store)
	fires := make(map[string][dynamic]Fire, context.temp_allocator)
	measured := 0
	for commit, i in commits {
		if progress != nil {
			progress(i + 1, len(commits))
		}
		subject: string
		ok: bool
		records: []Record
		hit := false
		if !opts.fresh {
			subject, ok, hit = store_get(store, commit, context.temp_allocator)
			if hit && ok {
				records = store_fires(store, commit, context.temp_allocator)
			}
		}
		if !hit {
			subject, ok, records = measure(root, commit, context.temp_allocator)
			store_put(store, commit, subject, ok, records)
		}
		if !ok {
			continue // A root commit has no parent to diff against.
		}
		measured += 1
		for r in records {
			list := fires[r.rule]
			if list.allocator.procedure == nil {
				list = make([dynamic]Fire, context.temp_allocator)
			}
			append(&list, Fire{commit[:min(8, len(commit))], subject, r.message})
			fires[strings.clone(r.rule, context.temp_allocator)] = list
		}
	}
	b := strings.builder_make(allocator)
	if opts.rule != "" {
		listed_fires := fires[opts.rule]
		for f in listed_fires {
			fmt.sbprintf(
				&b,
				"%s  %s\n    %s\n",
				f.commit,
				f.subject,
				f.message[:min(160, len(f.message))],
			)
		}
		fmt.sbprintf(
			&b,
			"\n%s fired on %d of %d commits\n",
			opts.rule,
			len(listed_fires),
			measured,
		)
		return strings.to_string(b), ""
	}
	rules, _ := slice.map_keys(fires, context.temp_allocator)
	slice.sort_by_cmp(rules, proc(a, b: string) -> slice.Ordering {
		return .Less if a < b else (.Greater if a > b else .Equal)
	})
	// The most frequent first, the rest by name.
	counted = &fires
	slice.stable_sort_by(rules, proc(a, b: string) -> bool {
		return len(fires_of(a)) > len(fires_of(b))
	})
	counted = nil
	fmt.sbprintf(&b, "%d commits measured\n\n", measured)
	fmt.sbprintf(&b, "%-28s %6s  %s\n", "rule", "fires", "rate")
	for r in rules {
		count := strings.right_justify(
			fmt.tprintf("%d", len(fires[r])),
			6,
			" ",
			context.temp_allocator,
		)
		rate := strings.right_justify(
			fmt.tprintf("%.1f%%", 100 * f64(len(fires[r])) / f64(measured)),
			5,
			" ",
			context.temp_allocator,
		)
		fmt.sbprintf(&b, "%-28s %s  %s\n", r, count, rate)
	}
	if len(rules) == 0 {
		strings.write_string(&b, "nothing fired\n")
	}
	return strings.to_string(b), ""
}

// The fires under measurement, reachable from the sort's comparator,
// which cannot capture them.
@(private)
counted: ^map[string][dynamic]Fire

@(private)
fires_of :: proc(rule: string) -> [dynamic]Fire {
	if counted == nil {
		return {}
	}
	return counted[rule]
}

// measure reads one commit the way a review reads a change, and reports
// which rules fired. ok is false for a commit that cannot be measured at
// all — a root commit has no parent to diff against — which is records so
// that it is not retried on every run.
@(private)
measure :: proc(
	root, commit: string,
	allocator := context.allocator,
) -> (
	subject: string,
	ok: bool,
	out: []Record,
) {
	context.allocator = allocator
	rev := fmt.tprintf("%s^..%s", commit, commit)
	c, gathered := change.gather(rev, root, allocator)
	if !gathered {
		return "", false, nil
	}
	t, at_ok := tree.at(root, rev, allocator)
	if !at_ok {
		return "", false, nil
	}
	change.read(&c, t, allocator)
	c.index, _ = change.index(t, allocator)
	findings := check.run(check.scope_of(&c, t, allocator), allocator)
	tree.close(t) // One tree per commit; a bench must not keep them all.
	subject = strings.trim_space(c.message)
	if nl := strings.index_byte(subject, '\n'); nl >= 0 {
		subject = subject[:nl]
	}
	list := make([dynamic]Record, allocator)
	seen := make(map[string]bool, allocator)
	for f in findings {
		if seen[f.rule] {
			continue
		}
		seen[f.rule] = true
		append(&list, Record{f.rule, f.message})
	}
	return subject, true, list[:]
}
