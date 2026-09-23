package main

// A function's size and depth are measured, not judged. The thresholds
// were read off 8,255 functions in the repositories on the author's
// machine: length sits between the 95th percentile (109 lines) and the
// 99th (257); depth at the 99th (6).

import "fmt"

const (
	// maxFunctionLines is the length past which a function is several.
	maxFunctionLines = 150
	// maxNesting is the block depth past which a reader is holding more
	// context than the function's name gave them.
	maxNesting = 5
)

// checkShape reports a new function that is too long or too deeply
// nested to read as one thing.
func checkShape(c *Change) []Finding {
	var out []Finding
	for _, s := range c.Symbols {
		if s.Kind != "func" || s.Body == "" {
			continue
		}
		if n := lineCount(s.Body); n > maxFunctionLines {
			out = append(out, Finding{
				Job: "static", Rule: "function-too-long", Severity: Consider,
				File: s.File, Line: s.Line, Symbol: s.Name,
				Message: fmt.Sprintf("%s is %d lines, over the %d past which a function is several; 95%% of measured functions fit in 109", s.Name, n, maxFunctionLines),
				Fix:     "split it at the point where the reader has to remember what came before",
			})
		}
		if d := nesting(s.Body); d > maxNesting {
			out = append(out, Finding{
				Job: "static", Rule: "nesting-too-deep", Severity: Consider,
				File: s.File, Line: s.Line, Symbol: s.Name,
				Message: fmt.Sprintf("%s nests %d blocks deep, over the %d past which a reader is holding more than the name told them; 99%% of measured functions stay within 6", s.Name, d, maxNesting),
				Fix:     "return early, or lift the inner blocks into functions of their own",
			})
		}
	}
	return out
}

func lineCount(body string) int {
	n := 1
	for i := 0; i < len(body); i++ {
		if body[i] == '\n' {
			n++
		}
	}
	return n
}

// nesting is the deepest block within a body, counted by braces with
// strings and comments read through, less the body's own pair.
func nesting(body string) int {
	depth, deepest := 0, 0
	var (
		inString, inRaw, inLine, inBlock bool
		quote                            byte
	)
	for i := 0; i < len(body); i++ {
		c := body[i]
		switch {
		case inLine:
			if c == '\n' {
				inLine = false
			}
		case inBlock:
			if c == '*' && i+1 < len(body) && body[i+1] == '/' {
				inBlock = false
				i++
			}
		case inRaw:
			if c == '`' {
				inRaw = false
			}
		case inString:
			if c == '\\' {
				i++
			} else if c == quote || c == '\n' {
				inString = false
			}
		case c == '/' && i+1 < len(body) && body[i+1] == '/':
			inLine = true
		case c == '/' && i+1 < len(body) && body[i+1] == '*':
			inBlock = true
		case c == '`':
			inRaw = true
		case c == '"' || c == '\'':
			inString, quote = true, c
		case c == '{':
			depth++
			deepest = max(deepest, depth)
		case c == '}':
			depth--
		}
	}
	return max(deepest-1, 0)
}
