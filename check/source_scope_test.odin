package check

import "core:strings"

import "../change"

@(private)
source_line :: proc(src, frag: string) -> int {
	at := strings.index(src, frag)
	if at < 0 {
		return 0
	}
	line := 1
	for ch in src[:at] {
		if ch == '\n' {
			line += 1
		}
	}
	return line
}

@(private)
source_every_line :: proc(src: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	line := 1
	append(&out, line)
	for ch in src {
		if ch == '\n' {
			line += 1
			append(&out, line)
		}
	}
	return out[:]
}

@(private)
scope_from_source :: proc(path, src: string, lines: []int) -> Scope {
	c := new(change.Change, context.temp_allocator)
	c.added = make(map[string][dynamic]change.Diff_Line, context.temp_allocator)
	text := strings.split(src, "\n", context.temp_allocator)
	added := make([dynamic]change.Diff_Line, context.temp_allocator)
	for n in lines {
		if n >= 1 && n <= len(text) {
			append(&added, change.Diff_Line{n, text[n - 1]})
		}
	}
	c.added[path] = added
	sources := make(map[string][]byte, context.temp_allocator)
	sources[path] = transmute([]byte)src
	return Scope {
		c = c,
		sources = sources,
	}
}
