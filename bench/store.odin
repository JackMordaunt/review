/*
The bench's memo.

Measuring a commit is deterministic: the same tree, read by the same
checks, fires the same rules. Recomputing that on every run is the whole
cost of a bench: a full measurement of every commit in range, where a
lookup would do. Compare `review bench -n 200 --fresh` against `review
bench -n 200` to see the difference on any given tree. The memo records
what each commit fired, keyed by a fingerprint of the ruleset, so a later
bench measures only what it has not seen.

It is an accelerator and never a dependency. A memo that will not open
makes every commit a miss, and the bench behaves exactly as it did before
there was one.
*/
package bench

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../check"

import "jm:sqlite3"

// version is bumped by hand when a rule's logic changes, which nothing can
// detect from outside. The set of rules is not left to memory: fingerprint
// hashes check.rules, so adding, removing or renaming a rule invalidates
// the memo on its own.
version :: "review-bench-v1"

// fingerprint is version and the ids of every deterministic check, hashed.
// It is what a measurement is keyed by, so a memo written under one set of
// rules is never replayed under another.
fingerprint :: proc() -> string {
	@(static) cached: string
	if cached != "" {
		return cached
	}
	ids := make([dynamic]string, context.temp_allocator)
	append(&ids, version)
	for r in check.rules {
		append(&ids, r.id)
	}
	joined := strings.join(ids[:], "\x00", context.temp_allocator)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)joined)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	cached = string(hex.encode(digest[:16], context.allocator))
	return cached
}

// Store is the memo. ready is false when it could not be opened, which is
// not an error: every lookup misses and nothing is kept.
Store :: struct {
	db:    sqlite3.Db,
	ready: bool,
}

// Record is one rule that fired on a commit, and what it said.
Record :: struct {
	rule, message: string,
}

@(private)
schema :: `
CREATE TABLE IF NOT EXISTS measured(
	sha     TEXT NOT NULL,
	version TEXT NOT NULL,
	subject TEXT NOT NULL,
	ok      INTEGER NOT NULL,
	PRIMARY KEY (sha, version)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS fire(
	sha     TEXT NOT NULL,
	version TEXT NOT NULL,
	rule    TEXT NOT NULL,
	message TEXT NOT NULL,
	PRIMARY KEY (sha, version, rule)
) WITHOUT ROWID;
`

// store_open opens the memo beside the answer cache. path is for tests.
store_open :: proc(path := "", allocator := context.allocator) -> (s: Store) {
	if path == "off" {
		return
	}
	location := path
	if location == "" {
		dir, err := os.user_cache_dir(context.temp_allocator)
		if err != nil {
			return
		}
		home := filepath.join({dir, "review"}, context.temp_allocator) or_else ""
		if home == "" {
			return
		}
		os.make_directory_all(home) // Already there is the common case.
		location = filepath.join({home, "bench.db"}, context.temp_allocator) or_else ""
		if location == "" {
			return
		}
	}
	db, err := sqlite3.open(
		location,
		sqlite3.Opts{wal = true, busy_timeout = 5 * time.Second},
		allocator,
	)
	if err != nil {
		return
	}
	if sqlite3.exec(db, schema) != nil {
		closing := db
		sqlite3.close(&closing)
		return
	}
	return Store{db = db, ready = true}
}

// store_close closes the memo. Closing one that never opened is a no-op.
store_close :: proc(s: ^Store) {
	if !s.ready {
		return
	}
	sqlite3.close(&s.db)
	s.ready = false
}

// store_get reports what was recorded for a commit. hit is false when this
// commit has not been measured at this version; ok is whether it could be
// measured at all, so that a root commit is not retried on every run.
store_get :: proc(
	s: Store,
	sha: string,
	allocator := context.allocator,
) -> (
	subject: string,
	ok: bool,
	hit: bool,
) {
	if !s.ready {
		return
	}
	context.allocator = allocator
	rows, err := sqlite3.query(
		s.db,
		`SELECT subject, ok FROM measured WHERE sha = ? AND version = ?`,
		sha,
		fingerprint(),
	)
	if err != nil {
		return
	}
	defer {
		closing := rows
		sqlite3.finish(&closing)
	}
	if sqlite3.next(&rows) {
		return sqlite3.text(rows, 0), sqlite3.integer(rows, 1) != 0, true
	}
	return
}

// store_fires returns the rules a measured commit fired, in rule order.
store_fires :: proc(s: Store, sha: string, allocator := context.allocator) -> []Record {
	if !s.ready {
		return nil
	}
	context.allocator = allocator
	out := make([dynamic]Record, allocator)
	rows, err := sqlite3.query(
		s.db,
		`SELECT rule, message FROM fire WHERE sha = ? AND version = ? ORDER BY rule`,
		sha,
		fingerprint(),
	)
	if err != nil {
		return out[:]
	}
	defer {
		closing := rows
		sqlite3.finish(&closing)
	}
	for sqlite3.next(&rows) {
		append(&out, Record{sqlite3.text(rows, 0), sqlite3.text(rows, 1)})
	}
	return out[:]
}

// store_put records one measured commit. A failure is ignored: the memo is
// an accelerator, and a bench that measured correctly must still report.
store_put :: proc(s: Store, sha, subject: string, ok: bool, fires: []Record) {
	if !s.ready {
		return
	}
	if sqlite3.exec_args(
		   s.db,
		   `INSERT OR REPLACE INTO measured(sha, version, subject, ok) VALUES (?, ?, ?, ?)`,
		   sha,
		   fingerprint(),
		   subject,
		   i64(1 if ok else 0),
	   ) !=
	   nil {
		return
	}
	for f in fires {
		sqlite3.exec_args(
			s.db,
			`INSERT OR REPLACE INTO fire(sha, version, rule, message) VALUES (?, ?, ?, ?)`,
			sha,
			fingerprint(),
			f.rule,
			f.message,
		)
	}
}

// store_begin and store_commit bracket a run's writes, so that measuring a
// hundred commits is one transaction rather than a hundred.
store_begin :: proc(s: Store) {
	if s.ready {
		sqlite3.exec(s.db, "BEGIN")
	}
}

store_commit :: proc(s: Store) {
	if s.ready {
		sqlite3.exec(s.db, "COMMIT")
	}
}
