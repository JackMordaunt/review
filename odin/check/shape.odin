package check

// A function's size and depth are measured, not judged. The thresholds
// were read off 8,255 functions: length sits between the 95th percentile
// (109 lines) and the 99th (257); depth at the 99th (6).

import "core:fmt"

import "../finding"

// max_function_lines is the length past which a function is several;
// max_nesting the block depth past which a reader is holding more
// context than the function's name gave them.
max_function_lines :: 150
max_nesting        :: 5

// check_shape reports a new function that is too long or too deeply
// nested to read as one thing.
check_shape :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for sym in s.c.symbols {
		if sym.kind != "func" || sym.body == "" {
			continue
		}
		if n := line_count(sym.body); n > max_function_lines {
			append(
				out,
				static(
					"function-too-long",
					.Consider,
					fmt.aprintf(
						"%s is %d lines, over the %d past which a function is several; 95%% of measured functions fit in 109",
						sym.name,
						n,
						max_function_lines,
					),
					"split it at the point where the reader has to remember what came before",
					file = sym.file,
					line = sym.line,
					symbol = sym.name,
				),
			)
		}
		if d := nesting(sym.body); d > max_nesting {
			append(
				out,
				static(
					"nesting-too-deep",
					.Consider,
					fmt.aprintf(
						"%s nests %d blocks deep, over the %d past which a reader is holding more than the name told them; 99%% of measured functions stay within 6",
						sym.name,
						d,
						max_nesting,
					),
					"return early, or lift the inner blocks into functions of their own",
					file = sym.file,
					line = sym.line,
					symbol = sym.name,
				),
			)
		}
	}
}

line_count :: proc(body: string) -> int {
	n := 1
	for i in 0 ..< len(body) {
		if body[i] == '\n' {
			n += 1
		}
	}
	return n
}

// nesting is the deepest block within a body, counted by braces with
// strings and comments read through, less the body's own pair.
nesting :: proc(body: string) -> int {
	depth, deepest := 0, 0
	in_string, in_raw, in_line, in_block: bool
	quote: byte
	i := 0
	for i < len(body) {
		c := body[i]
		switch {
		case in_line:
			if c == '\n' {
				in_line = false
			}
		case in_block:
			if c == '*' && i + 1 < len(body) && body[i + 1] == '/' {
				in_block = false
				i += 1
			}
		case in_raw:
			if c == '`' {
				in_raw = false
			}
		case in_string:
			if c == '\\' {
				i += 1
			} else if c == quote || c == '\n' {
				in_string = false
			}
		case c == '/' && i + 1 < len(body) && body[i + 1] == '/':
			in_line = true
		case c == '/' && i + 1 < len(body) && body[i + 1] == '*':
			in_block = true
		case c == '`':
			in_raw = true
		case c == '"' || c == '\'':
			in_string, quote = true, c
		case c == '{':
			depth += 1
			deepest = max(deepest, depth)
		case c == '}':
			depth -= 1
		}
		i += 1
	}
	return max(deepest - 1, 0)
}
