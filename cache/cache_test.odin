package cache

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../provider"

@(test)
answers_replay_across_opens :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	temp := os.temp_directory(context.temp_allocator) or_else ""
	dir, err := os.make_directory_temp(temp, "review-cache-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	path := filepath.join({dir, "deep", "answers.json"}, context.temp_allocator) or_else ""

	c, ok := open(false, path)
	testing.expect(t, ok)
	_, hit := get(c, "p", "s", "u")
	testing.expect(t, !hit, "an empty cache replays nothing")
	put(c, "p", "s", "u", provider.Answer{text = "answer", tokens_in = 3, cost = 0.1})
	got, replayed := get(c, "p", "s", "u")
	testing.expect(t, replayed)
	testing.expect_value(t, got.text, "answer")
	testing.expect(t, got.replayed)
	testing.expect_value(t, got.tokens_in, 0)
	save(c)

	again, opened := open(false, path)
	testing.expect(t, opened)
	got, replayed = get(again, "p", "s", "u")
	testing.expect(t, replayed, "the saved answer is read back")
	testing.expect_value(t, got.text, "answer")
	_, other := get(again, "other", "s", "u")
	testing.expect(t, !other, "another provider's question is another question")

	fresh, _ := open(true, path)
	_, skipped := get(fresh, "p", "s", "u")
	testing.expect(t, !skipped, "fresh reads nothing")
	testing.expect(t, key("a", "b", "c") != key("a", "b", "d"))

	// The Go tool's file, with its RFC 3339 times, is read as it stands.
	shared := filepath.join({dir, "go.json"}, context.temp_allocator) or_else ""
	entry := key("p", "s", "u")
	testing.expect(
		t,
		os.write_entire_file(
			shared,
			transmute([]byte)strings.concatenate(
				{
					`{"`,
					entry,
					`":{"text":"from go","in":1,"out":2,"cached":0,"cost":0.1,"at":"2026-09-23T20:55:09.673084018-03:00"}}`,
				},
			),
		) ==
		nil,
	)
	theirs, ok_theirs := open(false, shared)
	testing.expect(t, ok_theirs)
	from_go, replayed_go := get(theirs, "p", "s", "u")
	testing.expect(t, replayed_go, "the Go tool's answer replays")
	testing.expect_value(t, from_go.text, "from go")
	testing.expect_value(t, len(stamp()), 20)

	// A file that cannot be read is not written over.
	broken := filepath.join({dir, "broken.json"}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(broken, transmute([]byte)string("not json")) == nil)
	guarded, _ := open(false, broken)
	put(guarded, "p", "s", "u", provider.Answer{text = "mine"})
	save(guarded)
	kept, _ := os.read_entire_file_from_path(broken, context.temp_allocator)
	testing.expect_value(t, string(kept), "not json")
	testing.expect_value(t, len(key("a", "b", "c")), 64)
}
