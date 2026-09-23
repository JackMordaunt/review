package main

import (
	"cmp"
	"fmt"
	"slices"
	"strings"
)

// Declared is one declaration somewhere in the repository, which a new name
// might turn out to duplicate.
type Declared struct {
	Name string
	Kind string
	File string
	Line int
	// Text is the line it was declared on, which is what shows a reader that
	// two constants hold the same number.
	Text string
	// Body is the whole declaration where it has one, for the checks that
	// compare two functions rather than two names.
	Body string
}

func (d Declared) String() string {
	return fmt.Sprintf("%s:%d: %s", d.File, d.Line, strings.TrimSpace(d.Text))
}

// Resembling returns the declarations whose names share a word with the
// one given, which is the shortlist a reader is asked to judge. Words are
// matched whole, so that cache does not pull in every Cached, and the list
// is ranked: the more words shared the higher, a declaration of the same
// kind above one of another, and the same file above the rest. Its own
// declaration is left out, since a name always resembles itself.
func Resembling(index []Declared, symbol Symbol, limit int) []string {
	wanted := map[string]bool{}
	for _, word := range split(symbol.Name) {
		if len(word) >= 4 {
			wanted[depluralise(strings.ToLower(word))] = true
		}
	}
	if len(wanted) == 0 {
		return nil
	}
	type candidate struct {
		line  string
		score int
		order int
	}
	var out []candidate
	seen := map[string]bool{}
	for i, declared := range index {
		if declared.File == symbol.File && declared.Line == symbol.Line {
			continue
		}
		shared := 0
		for _, word := range split(declared.Name) {
			if wanted[depluralise(strings.ToLower(word))] {
				shared++
			}
		}
		if shared == 0 {
			continue
		}
		line := declared.String()
		if seen[line] {
			continue
		}
		seen[line] = true
		score := shared * 4
		if declared.Kind == symbol.Kind {
			score += 2
		}
		if declared.File == symbol.File {
			score++
		}
		out = append(out, candidate{line, score, i})
	}
	slices.SortFunc(out, func(a, b candidate) int {
		if c := cmp.Compare(b.score, a.score); c != 0 {
			return c
		}
		return cmp.Compare(a.order, b.order)
	})
	if len(out) > limit {
		out = out[:limit]
	}
	lines := make([]string, len(out))
	for i, r := range out {
		lines[i] = r.line
	}
	return lines
}

// same reports whether two declarations hold the same literal, which is the
// cheapest signal that a fact has been written twice. It is a hint for the
// shortlist, not a finding.
func same(a, b Declared) bool {
	_, left, okA := cutLiteral(a.Text)
	_, right, okB := cutLiteral(b.Text)
	return okA && okB && strings.TrimSpace(left) == strings.TrimSpace(right)
}

// cutLiteral takes the value half of a declaration line. Go and TypeScript
// write `name = value`; Odin writes `name :: value`.
func cutLiteral(text string) (string, string, bool) {
	if _, right, ok := strings.Cut(text, "="); ok {
		return text, right, true
	}
	if _, right, ok := strings.Cut(text, "::"); ok {
		return text, right, true
	}
	return text, "", false
}

// split breaks a name into the words it is made of, so that Assemble finds
// assemble and icoEntrySize finds both Entry and Size.
func split(name string) []string {
	var (
		words []string
		word  strings.Builder
	)
	for i, r := range name {
		// A capital starts a word; an underscore ends one, as snake_case
		// languages put the next word after it.
		if i > 0 && (r >= 'A' && r <= 'Z' || r == '_') {
			if word.Len() > 0 {
				words = append(words, word.String())
				word.Reset()
			}
			if r != '_' {
				word.WriteRune(r)
			}
			continue
		}
		word.WriteRune(r)
	}
	if word.Len() > 0 {
		words = append(words, word.String())
	}
	return words
}
