package change

// For every new name, the existing declarations that might already mean
// the same thing. Finding them is the cheap part; judging the shortlist is
// what the duplication job is for.

import "core:fmt"
import "core:slice"
import "core:strings"

import "../txt"

// shortlist is how many resembling declarations a new name is shown
// beside, ranked; the twins come before them and are not counted.
shortlist :: 12

// find_candidates gathers, per new name, the declarations holding the
// same literal — the strongest hint a fact has been written twice — and
// then the ones whose names share a word. Both are kept on the change,
// keyed by the new name.
find_candidates :: proc(c: ^Change, allocator := context.allocator) {
	context.allocator = allocator
	c.twins = make(map[string][]string)
	c.candidates = make(map[string][]string)
	for symbol in c.symbols {
		twins := make([dynamic]string)
		for declared in c.index {
			if declared.file == symbol.file && declared.line == symbol.line {
				continue
			}
			if same(declared.text, symbol.signature) {
				append(
					&twins,
					fmt.aprintf("%s   <- same value", describe(declared, context.temp_allocator)),
				)
			}
		}
		if len(twins) > 0 {
			c.twins[symbol.name] = twins[:]
		}
		near := resembling(c.index, symbol, shortlist)
		listed := make([dynamic]string)
		append(&listed, ..twins[:])
		append(&listed, ..near)
		c.candidates[symbol.name] = listed[:]
	}
}

// describe is a declaration as the shortlist names it: where it is, and
// the line it was declared on.
describe :: proc(d: Declared, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s:%d: %s",
		d.file,
		d.line,
		strings.trim_space(d.text),
		allocator = allocator,
	)
}

// resembling returns the declarations whose names share a word with the
// one given, which is the shortlist a reader is asked to judge. Words are
// matched whole, so that cache does not pull in every Cached, and the
// list is ranked: the more words shared the higher, a declaration of the
// same kind above one of another, and the same file above the rest.
resembling :: proc(
	index: []Declared,
	symbol: Symbol,
	limit: int,
	allocator := context.allocator,
) -> []string {
	wanted := make(map[string]bool, context.temp_allocator)
	for word in txt.split_words(symbol.name, context.temp_allocator) {
		if len(word) >= 4 {
			wanted[txt.depluralise(strings.to_lower(word, context.temp_allocator))] = true
		}
	}
	if len(wanted) == 0 {
		return nil
	}
	Candidate :: struct {
		line:  string,
		score: int,
		order: int,
	}
	out := make([dynamic]Candidate, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for declared, i in index {
		if declared.file == symbol.file && declared.line == symbol.line {
			continue
		}
		shared := 0
		for word in txt.split_words(declared.name, context.temp_allocator) {
			if wanted[txt.depluralise(strings.to_lower(word, context.temp_allocator))] {
				shared += 1
			}
		}
		if shared == 0 {
			continue
		}
		line := describe(declared, context.temp_allocator)
		if seen[line] {
			continue
		}
		seen[line] = true
		score := shared * 4
		if declared.kind == symbol.kind {
			score += 2
		}
		if declared.file == symbol.file {
			score += 1
		}
		append(&out, Candidate{line, score, i})
	}
	slice.sort_by_cmp(out[:], proc(a, b: Candidate) -> slice.Ordering {
		if a.score != b.score {
			return .Less if a.score > b.score else .Greater
		}
		return .Less if a.order < b.order else (.Greater if a.order > b.order else .Equal)
	})
	kept := out[:min(len(out), limit)]
	lines := make([]string, len(kept), allocator)
	for r, i in kept {
		lines[i] = strings.clone(r.line, allocator)
	}
	return lines
}

// same reports whether two declaration lines hold the same literal. Go
// and TypeScript write `name = value`; Odin writes `name :: value`.
same :: proc(a, b: string) -> bool {
	left, ok_a := literal_of(a)
	right, ok_b := literal_of(b)
	return ok_a && ok_b && strings.trim_space(left) == strings.trim_space(right)
}

literal_of :: proc(text: string) -> (string, bool) {
	if i := strings.index_byte(text, '='); i >= 0 {
		return text[i + 1:], true
	}
	if i := strings.index(text, "::"); i >= 0 {
		return text[i + 2:], true
	}
	return "", false
}
