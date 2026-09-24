package provider

// A chain is a priority order of providers. The first one that answers a
// probe serves the whole reading, so a provider over its limit costs one
// cheap ask rather than a failed review. Which provider is reachable is a
// property of the hour: a team limit exhausted, a gateway asleep, a key
// unset — the chain is how the tool rides that out without being told.

import "core:fmt"
import "core:os"
import "core:strings"

// Entry is one provider in the order, under the name it is reported as.
Entry :: struct {
	name:     string,
	provider: Provider,
}

// default_chain is the configured preference: the direct API, then the
// coding assistant on the path, then the local gateway as the reading of
// last resort. The order is a choice about where an answer is likeliest
// to be had with the least fuss, not a claim about any of them; a probe
// decides. REVIEW_MODEL re-points the first slot.
default_chain :: proc(allocator := context.temp_allocator) -> []Entry {
	model := os.get_env("REVIEW_MODEL", allocator)
	if model == "" {
		model = default_api_model
	}
	entries := make([]Entry, 3, allocator)
	entries[0] = Entry{strings.concatenate({"api/", model}, allocator), Provider{kind = .Api, model = model}}
	entries[1] = Entry{strings.concatenate({"claude/", default_claude_model}, allocator), Provider{kind = .Claude, model = default_claude_model}}
	entries[2] = Entry{"pi/maple/glm-5-3-flash", Provider{kind = .Pi, model = "glm-5-3-flash", upstream = "maple"}}
	return entries
}

// pick asks every entry a trivial question, in order, and returns the
// first that answers. Every failure is told through warn, so a review run
// on the second choice says why the first was passed over, in one line.
pick :: proc(
	chain: []Entry,
	warn: proc(msg: string),
	allocator := context.allocator,
) -> (
	p: Provider,
	picked: string,
	err: string,
) {
	reasons := make([dynamic]string, context.temp_allocator)
	for e in chain {
		answer, ask_err := ask(
			e.provider,
			"Answer the user's message.",
			"Answer with the single word OK.",
			context.temp_allocator,
		)
		if ask_err == "" && strings.trim_space(answer.text) != "" {
			return e.provider, strings.clone(e.name, allocator), ""
		}
		why := ask_err if ask_err != "" else "answered nothing"
		if i := strings.index_any(why, "\r\n"); i >= 0 {
			why = why[:i]
		}
		warn(fmt.tprintf("skipping %s: %s", e.name, why))
		append(&reasons, fmt.tprintf("%s: %s", e.name, why))
	}
	return {}, "", fmt.aprintf("no provider answered: %s", strings.join(reasons[:], "; ", context.temp_allocator), allocator = allocator)
}
