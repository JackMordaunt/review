package cache

import "core:os"
import "core:path/filepath"
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
	testing.expect_value(t, len(key("a", "b", "c")), 64)
}
