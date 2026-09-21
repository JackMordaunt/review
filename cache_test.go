package main

// The answer cache is what makes a re-run cheap and stable where the part
// of the change being judged did not change. These tests hold the contract:
// a recorded question replays and counts no usage, an unrecorded one asks,
// a fresh cache asks but keeps writing, a corrupt file is survived, and the
// file is pruned rather than grown without bound.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testCache(t *testing.T) *AnswerCache {
	t.Helper()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	cache := openCache(false)
	if cache == nil {
		t.Fatal("no cache")
	}
	return cache
}

func TestCacheReplaysAndRecords(t *testing.T) {
	cache := testCache(t)
	// Nothing is recorded yet.
	if _, ok := cache.get("api/probe", "system", "user"); ok {
		t.Error("an unrecorded question was replayed")
	}
	cache.put("api/probe", "system", "user", Answer{Text: "answer", In: 10, Out: 2, Cost: 0.5})
	// A replay is the same text, marked as a replay, and counts no usage:
	// it cost nothing this run.
	answer, ok := cache.get("api/probe", "system", "user")
	if !ok || answer.Text != "answer" || !answer.Replayed || answer.In != 0 || answer.Cost != 0 {
		t.Errorf("got %+v", answer)
	}
	// A different question is not a replay.
	for _, key := range [][3]string{
		{"api/probe", "system", "other user"},
		{"api/probe", "other system", "user"},
		{"api/other", "system", "user"},
	} {
		if _, ok := cache.get(key[0], key[1], key[2]); ok {
			t.Errorf("replayed %v", key)
		}
	}
	// What was recorded survives the run.
	cache.save()
	again := openCache(false)
	if answer, ok := again.get("api/probe", "system", "user"); !ok || answer.Text != "answer" {
		t.Errorf("got %+v", answer)
	}
}

// Fresh is for when the answer itself is in doubt: it asks again, and
// leaves what it learned behind it.
func TestCacheFreshAsksAndKeepsWriting(t *testing.T) {
	cache := testCache(t)
	cache.put("api/probe", "system", "user", Answer{Text: "stale"})
	fresh := openCache(true)
	if _, ok := fresh.get("api/probe", "system", "user"); ok {
		t.Error("fresh replayed a recorded answer")
	}
	fresh.put("api/probe", "system", "other", Answer{Text: "new"})
	fresh.save()
	// The write is on disk, so it is read back from a new cache.
	after := openCache(false)
	if answer, ok := after.get("api/probe", "system", "other"); !ok || answer.Text != "new" {
		t.Errorf("got %+v", answer)
	}
}

func TestCacheToleratesCorruption(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "review"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "review", "answers.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	cache := openCache(false)
	cache.put("api/probe", "system", "user", Answer{Text: "kept"})
	cache.save()
	data, err := os.ReadFile(filepath.Join(dir, "review", "answers.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "kept") {
		t.Errorf("got %s", data)
	}
}

func TestCachePrunesTheOldest(t *testing.T) {
	cache := testCache(t)
	for i := range cacheBound + 10 {
		cache.put(string(rune('a'+i%26))+itoa(i), "system", "user", Answer{Text: "x"})
	}
	cache.save()
	again := openCache(false)
	if len(again.entries) != cacheBound {
		t.Errorf("kept %d, want %d", len(again.entries), cacheBound)
	}
}

// A reviewer with a cache asks once and replays from then on, and the
// replay carries the findings the first ask produced.
func TestReviewerReplaysWhatItAsked(t *testing.T) {
	provider := &relenting{answers: []string{findingsJSON("cannot-fail")}}
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	cache := openCache(false)
	jobs, err := chosen("tests")
	if err != nil {
		t.Fatal(err)
	}
	first := Reviewer{Provider: provider, Cache: cache}.Run(context.Background(), verifyChange(), jobs)
	if len(first.Findings) != 1 || first.Replayed != 0 {
		t.Fatalf("got %+v", first)
	}
	asked := len(provider.asked)
	second := Reviewer{Provider: provider, Cache: cache}.Run(context.Background(), verifyChange(), jobs)
	if len(provider.asked) != asked {
		t.Errorf("asked %d times on the second run", len(provider.asked)-asked)
	}
	if second.Replayed != 1 {
		t.Errorf("got %+v", second)
	}
	if len(second.Findings) != 1 || second.Findings[0].Rule != "cannot-fail" {
		t.Fatalf("got %+v", second.Findings)
	}
	// A fresh cache asks again even where the answer is recorded.
	fresh := openCache(true)
	third := Reviewer{Provider: provider, Cache: fresh}.Run(context.Background(), verifyChange(), jobs)
	if third.Replayed != 0 || len(provider.asked) != asked+1 {
		t.Errorf("fresh replayed: %+v", third)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for ; n > 0; n /= 10 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
	}
	return string(digits)
}
