package check

// The rules are what an agent is handed. A finding cites one by id, and
// the id has to lead somewhere: the description of the deterministic check
// that measured it. Printing them from the binary is what makes the rules
// travel with it.

import "core:fmt"
import "core:strings"

// Rule describes one deterministic check, for the reader who met its id
// in a finding.
Rule :: struct {
	id:          string,
	description: string,
}

// rules are the deterministic checks, in the order the readme lists
// them. Each id here is one a finding can carry with job "static".
rules := []Rule {
	{
		"go-build",
		"the Go compiler cannot build a package the change touched; must-fix wherever the error lands",
	},
	{
		"go-vet/<analyzer>",
		"go vet's finding, on a line the change adds — with review-vet's extra analysers where it is installed; nilness and vet's own set are must-fix, shadow and unusedwrite consider, modernize note",
	},
	{
		"staticcheck/<code>",
		"the Go analyser's finding, on a line the change adds; SA is must-fix, S and U consider, the rest note",
	},
	{
		"odin-check",
		"odin check -vet -strict-style cannot check a package the change touched: a type error is must-fix wherever it lands, a vet failure consider, a style failure note",
	},
	{
		"tsc/<code>",
		"the TypeScript compiler's error under the project's own tsconfig; must-fix wherever it lands; working tree only",
	},
	{
		"ruff/<code>",
		"ruff's finding on a line the change adds; pyflakes codes consider, style codes note",
	},
	{
		"mypy/<code>",
		"mypy's type error on a line the change adds, missing imports ignored; working tree only",
	},
	{
		"cargo/<code>",
		"cargo check's — or clippy's — diagnostic: an error is must-fix wherever it lands, a warning consider on a line the change adds",
	},
	{
		"semgrep/<rule>",
		"a semgrep match on a line the change adds, under the repository's own .semgrep.yml or the registry's p/default pack; the rule's severity is kept: ERROR must-fix, WARNING consider, INFO note",
	},
	{
		"message-low-entropy",
		"the commit message's Shannon entropy is under 3.2 bits per byte: a phrase repeated rather than a description",
	},
	{
		"message-boilerplate",
		"the commit message keeps under 20% of its length after zlib: a block of text pasted or repeated whole",
	},
	{
		"message-common-words",
		"the commit message is made only of the repository's commonest commit words and names nothing the change touches",
	},
	{
		"message-frustration",
		"the commit message is an exclamation — oops, whoops, damn — where a description should be",
	},
	{
		"message-not-imperative",
		"the subject's first word after its package prefix is past tense, a gerund, or the author",
	},
	{
		"message-no-body",
		"a change over 50 lines carries no body, and the diff does not only move text around",
	},
	{"message-long-body", "the body is over 150 words, listing what the diff already shows"},
	{
		"history-coupled-file",
		"history ties a changed file to a partner the change does not touch: Jaccard at least 0.7 over at least 5 shared commits",
	},
	{
		"message-names-unknown",
		"the commit message names an identifier, path or call that is in neither the diff nor the repository at the end of the change",
	},
	{
		"formatting-mixed-in",
		"half or more of the change's lines change only whitespace, and at least 10 change something else: a reformatting with logic in it",
	},
	{
		"suppression-added",
		"the change adds its own review:ignore dismissal, before the readers have run",
	},
	{"test-deleted", "the change deletes a test function that no added test renames"},
	{"no-stutter", "an exported name's first word is its package: ico.IcoEntry says ico twice"},
	{
		"no-shadow",
		"a new name is a predeclared identifier, a standard library package, a runtime global, or a shell builtin",
	},
	{"abbreviation", "a new name carries an invented abbreviation: cfg, mgr, hdlr, svc, btn, cnt"},
	{
		"test-no-assertion",
		"an added or altered test has no call that could fail it; it can only fail by crashing",
	},
	{
		"assertion-always-true",
		"an assertion in an added or altered test holds whatever the code does: a literal true, two literals, or a value against itself",
	},
	{
		"duplicate-body",
		"a new function's body already exists, token for token (must-fix) or in shape with every name changed (consider)",
	},
	{
		"function-too-long",
		"a new function is over 150 lines; 95% of measured functions fit in 109",
	},
	{
		"nesting-too-deep",
		"a new function nests blocks more than 5 deep; 99% of measured functions stay within 6",
	},
	{
		"comment-restates-code",
		"every content word of an added comment is in the line of code below it",
	},
	{
		"todo-without-reference",
		"an added TODO, FIXME, XXX or HACK names no issue, ticket, link or person",
	},
	{
		"commented-out-code",
		"an added comment run holds code: two statement-shaped lines, or one beyond doubt, an example the comment sets off by indenting or fencing aside",
	},
	{
		"debug-leftover",
		"an added line is a debugger statement, a breakpoint, dbg!, spew.Dump, console.log, set -x, or a DEBUG print",
	},
	{
		"error-swallowed",
		"an added line drops an error: _ = err, an empty catch, an except that passes",
	},
	{
		"odin-destroy-incomplete",
		"an Odin struct's destroy, free or deinit procedure never hands an owning field — a string, slice, map, dynamic array, pointer or struct with its own destroy — to any call, where the change adds the field or touches the procedure; an arena freed whole spares the struct",
	},
	{
		"odin-temp-in-loop",
		"an added Odin line allocates from the temp allocator inside a loop that no guard, begin or free_all in it resets: growth no leak check sees",
	},
	{
		"new-symbol-unreferenced",
		"nothing in the repository refers to a new declaration but its own line",
	},
	{
		"code-without-tests",
		"the change adds 50 or more lines of code, touches no test, and the repository keeps tests",
	},
}

// catalogue is every rule, as review rules prints them.
catalogue :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Deterministic checks\n\n")
	for r in rules {
		fmt.sbprintf(&b, "- `%s` — %s\n", r.id, r.description)
	}
	return strings.to_string(b)
}

// describe is one rule's description, by its id or by the family a
// tool's rules share: go-vet/anything is go-vet/<analyzer>.
describe :: proc(id: string) -> (description: string, ok: bool) {
	family := id
	if i := strings.index_byte(id, '/'); i >= 0 {
		family = id[:i]
	}
	for r in rules {
		if r.id == id ||
		   (strings.contains(id, "/") &&
				   strings.has_prefix(
					   r.id,
					   strings.concatenate({family, "/"}, context.temp_allocator),
				   )) {
			return r.description, true
		}
	}
	return "", false
}
