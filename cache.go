package main

// The cache remembers what a provider answered, so that a re-run of a
// review whose parts did not change does not ask again. A loop iterates by
// re-running: one fix, one more reading. Without the cache every re-run
// re-asks every job, at full price and with a fresh roll of the dice — the
// same question answered two ways is the flicker that makes a loop chase
// ghosts. With it, a job whose rendered subject is byte for byte the same
// replays the recorded answer, which is both free and stable.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// cacheVersion is part of every key, so that a change to what an ask holds
// invalidates the recorded answers instead of replaying stale ones.
const cacheVersion = "review-answers-v1"

// cacheBound is the entry count past which the oldest answers are dropped.
const cacheBound = 4000

// AnswerCache is one file of recorded answers, keyed by the exact question.
type AnswerCache struct {
	mu      sync.Mutex
	path    string
	fresh   bool
	entries map[string]cacheEntry
	dirty   bool
	hits    int
}

// cacheEntry is one recorded answer and what it cost when it was asked.
type cacheEntry struct {
	Text   string    `json:"text"`
	In     int       `json:"in"`
	Out    int       `json:"out"`
	Cached int       `json:"cached"`
	Cost   float64   `json:"cost"`
	At     time.Time `json:"at"`
}

// openCache reads the answer file from the user's cache directory. A cache
// that cannot be read or written is no fault of the review: the run asks
// the provider as it would have. Fresh skips the reads but keeps the
// writes, so --fresh re-asks everything and leaves the answers behind it.
func openCache(fresh bool) *AnswerCache {
	dir, err := os.UserCacheDir()
	if err != nil {
		return nil
	}
	c := &AnswerCache{
		path:    filepath.Join(dir, "review", "answers.json"),
		fresh:   fresh,
		entries: map[string]cacheEntry{},
	}
	data, err := os.ReadFile(c.path)
	if err != nil {
		return c // No cache yet, which is not an error.
	}
	// A corrupt file is answered with whatever parsed. The rest is
	// discarded rather than repaired; the next save rewrites the file.
	json.Unmarshal(data, &c.entries)
	return c
}

func (c *AnswerCache) key(provider, system, user string) string {
	h := sha256.Sum256([]byte(strings.Join([]string{cacheVersion, provider, system, user}, "\x00")))
	return hex.EncodeToString(h[:])
}

// get returns the answer recorded for exactly this question, marked as a
// replay: the run asked nothing, so the replay's usage counts stay at zero.
func (c *AnswerCache) get(provider, system, user string) (Answer, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fresh {
		return Answer{}, false
	}
	entry, ok := c.entries[c.key(provider, system, user)]
	if !ok {
		return Answer{}, false
	}
	c.hits++
	return Answer{Text: entry.Text, Replayed: true}, true
}

func (c *AnswerCache) put(provider, system, user string, answer Answer) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[c.key(provider, system, user)] = cacheEntry{
		Text: answer.Text, In: answer.In, Out: answer.Out,
		Cached: answer.Cached, Cost: answer.Cost, At: time.Now(),
	}
	c.dirty = true
}

// save writes the file back when this run recorded anything, dropping the
// oldest entries past the bound. A failed write stays silent: the cache is
// a saving, not a result.
func (c *AnswerCache) save() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.dirty {
		return
	}
	if len(c.entries) > cacheBound {
		type aged struct {
			key string
			at  time.Time
		}
		ages := make([]aged, 0, len(c.entries))
		for key, entry := range c.entries {
			ages = append(ages, aged{key, entry.At})
		}
		sort.Slice(ages, func(i, j int) bool { return ages[i].at.Before(ages[j].at) })
		for _, a := range ages[:len(ages)-cacheBound] {
			delete(c.entries, a.key)
		}
	}
	data, err := json.Marshal(c.entries)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(c.path), 0o755); err != nil {
		return
	}
	temp := c.path + ".tmp"
	if err := os.WriteFile(temp, data, 0o644); err != nil {
		return
	}
	os.Rename(temp, c.path)
}
