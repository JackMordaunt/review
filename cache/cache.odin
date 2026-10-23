/*
Package cache remembers what a provider answered, so that a re-run of a
review whose parts did not change does not ask again. A loop iterates by
re-running: one fix, one more reading. Without the cache every re-run
re-asks every job, at full price and with a fresh roll of the dice — the
same question answered two ways is the flicker that makes a loop chase
ghosts. With it, a job whose rendered subject is byte for byte the same
replays the recorded answer, which is both free and stable.
*/
package cache

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "../provider"

// version is part of every key, so that a change to what an ask holds
// invalidates the recorded answers instead of replaying stale ones.
version :: "review-answers-v1"

// bound is the entry count past which the oldest answers are dropped.
bound :: 4000

// Entry is one recorded answer and what it cost when it was asked. The
// time is written as the Go tool writes it, RFC 3339 with the local
// offset, so that either tool reads the other's file.
Entry :: struct {
	text:       string `json:"text"`,
	tokens_in:  int `json:"in"`,
	tokens_out: int `json:"out"`,
	cached:     int `json:"cached"`,
	cost:       f64 `json:"cost"`,
	at:         string `json:"at"`,
}

// Cache is one file of recorded answers, keyed by the exact question.
// fresh skips the reads but keeps the writes, so --fresh re-asks
// everything and leaves the answers behind it. A file that was there and
// could not be read is kept out of harm's way: nothing is written over
// it, since a save would replace every answer it holds with this run's
// few.
Cache :: struct {
	path:      string,
	fresh:     bool,
	entries:   map[string]Entry,
	dirty:     bool,
	hits:      int,
	protected: bool,
	lock:      sync.Mutex,
}

// open reads the answer file from the user's cache directory, or the path
// given. A cache that cannot be read is no fault of the review: the run
// asks the provider as it would have. A corrupt file is answered with
// nothing; the next save rewrites it.
open :: proc(fresh: bool, path := "", allocator := context.allocator) -> (c: ^Cache, ok: bool) {
	location := path
	if location == "" {
		dir, err := os.user_cache_dir(context.temp_allocator)
		if err != nil {
			return nil, false
		}
		location = filepath.join({dir, "review", "answers.json"}, allocator) or_else ""
	} else {
		location = strings.clone(path, allocator)
	}
	c = new(Cache, allocator)
	c.path = location
	c.fresh = fresh
	c.entries = make(map[string]Entry, allocator)
	data, err := os.read_entire_file_from_path(location, context.temp_allocator)
	if err != nil {
		return c, true // No cache yet, which is not an error.
	}
	loaded: map[string]Entry
	if json.unmarshal(data, &loaded, allocator = allocator) == nil {
		c.entries = loaded
	} else if len(data) > 0 {
		c.protected = true
	}
	return c, true
}

// key is the question, hashed with the provider that was asked and the
// cache's version.
key :: proc(provider_name, system, user: string, allocator := context.allocator) -> string {
	joined := strings.join({version, provider_name, system, user}, "\x00", context.temp_allocator)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)joined)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:], allocator))
}

// get returns the answer recorded for exactly this question, marked as a
// replay: the run asked nothing, so the replay's usage counts stay at
// zero.
get :: proc(
	c: ^Cache,
	provider_name, system, user: string,
	allocator := context.allocator,
) -> (
	provider.Answer,
	bool,
) {
	if c == nil {
		return {}, false
	}
	sync.mutex_lock(&c.lock)
	defer sync.mutex_unlock(&c.lock)
	if c.fresh {
		return {}, false
	}
	entry, found := c.entries[key(provider_name, system, user, context.temp_allocator)]
	if !found {
		return {}, false
	}
	c.hits += 1
	return provider.Answer{text = strings.clone(entry.text, allocator), replayed = true}, true
}

// put records an answer under its question.
put :: proc(c: ^Cache, provider_name, system, user: string, answer: provider.Answer) {
	if c == nil {
		return
	}
	sync.mutex_lock(&c.lock)
	defer sync.mutex_unlock(&c.lock)
	c.entries[key(provider_name, system, user)] = Entry {
		text       = strings.clone(answer.text),
		tokens_in  = answer.tokens_in,
		tokens_out = answer.tokens_out,
		cached     = answer.cached,
		cost       = answer.cost,
		at         = stamp(),
	}
	c.dirty = true
}

// stamp is the present, as RFC 3339 in UTC, which sorts as it ages and
// which the Go tool's reader accepts.
stamp :: proc(allocator := context.allocator) -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, sec := time.clock_from_time(now)
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		int(mo),
		d,
		h,
		mi,
		sec,
		allocator = allocator,
	)
}

// save writes the file back when this run recorded anything, dropping the
// oldest entries past the bound. A failed write stays silent: the cache
// is a saving, not a result.
save :: proc(c: ^Cache) {
	if c == nil {
		return
	}
	sync.mutex_lock(&c.lock)
	defer sync.mutex_unlock(&c.lock)
	if !c.dirty || c.protected {
		return
	}
	if len(c.entries) > bound {
		Aged :: struct {
			key: string,
			at:  string,
		}
		ages := make([dynamic]Aged, context.temp_allocator)
		for k, e in c.entries {
			append(&ages, Aged{k, e.at})
		}
		slice.sort_by_cmp(ages[:], proc(a, b: Aged) -> slice.Ordering {
			return .Less if a.at < b.at else (.Greater if a.at > b.at else .Equal)
		})
		for a in ages[:len(ages) - bound] {
			delete_key(&c.entries, a.key)
		}
	}
	data, err := json.marshal(c.entries, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	// make_directory_all answers .Exist for a directory already there
	// (core/os/path_posix.odin, odin dev-2026-09), which after the first
	// save is every time; answers_replay_across_opens saves twice.
	if dir := filepath.dir(c.path); !os.is_dir(dir) && os.make_directory_all(dir) != nil {
		return
	}
	temp := strings.concatenate({c.path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(temp, data) != nil {
		return
	}
	os.rename(temp, c.path)
	c.dirty = false
}
