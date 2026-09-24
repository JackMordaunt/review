/*
Package txt is the few readings of plain text that several packages
share: the words a name is made of, a plural made singular, and the JSON
object inside an answer.
*/
package txt

import "core:strings"

// split_words breaks a name into the words it is made of: a capital
// starts a word, an underscore ends one, as snake_case languages put the
// next word after it.
split_words :: proc(name: string, allocator := context.allocator) -> []string {
	words := make([dynamic]string, allocator)
	start := 0
	for i in 0 ..< len(name) {
		c := name[i]
		if i > 0 && ((c >= 'A' && c <= 'Z') || c == '_') {
			if i > start {
				append(&words, name[start:i])
			}
			start = i + 1 if c == '_' else i
		}
	}
	if start < len(name) {
		append(&words, name[start:])
	}
	return words[:]
}

// depluralise drops a trailing s, except where dropping it would leave
// another: class stays class.
depluralise :: proc(w: string) -> string {
	if len(w) > 3 && strings.has_suffix(w, "s") && w[len(w) - 2] != 's' {
		return w[:len(w) - 1]
	}
	return w
}

// object finds the JSON object in a text that has prose around it: from
// the first brace to the last. Only a provider that can enforce a schema
// returns bare JSON; the rest wrap it in whatever they were minded to
// say, and a compiler prints its own prose before its JSON when it cannot
// even start.
object :: proc(s: string) -> (string, bool) {
	start := strings.index_byte(s, '{')
	end := strings.last_index_byte(s, '}')
	if start < 0 || end < start {
		return "", false
	}
	return s[start:end + 1], true
}
