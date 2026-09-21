package main

import (
	"strings"
)

// Heuristic reads the languages no parser frontend covers: the comment lines
// a change adds, by the prefixes those languages share. It is deliberately
// line-shaped, so it is right about prose and silent about declarations —
// a pattern over lines missing an indented constant inside a block is the
// mistake that built the real frontends.
type Heuristic struct{}

func (Heuristic) Name() string { return "heuristic" }

// Covers reports the languages whose comment shape it knows. Prose-only
// formats (markdown, configs) are left out: their text is not a comment, and
// the claims job would be asked to judge ordinary writing.
func (Heuristic) Covers(path string) bool {
	for _, ext := range []string{
		".odin", ".py", ".rb", ".rs", ".c", ".h", ".cc", ".cpp", ".hpp",
		".js", ".mjs", ".cjs", ".lua", ".zig", ".swift", ".kt", ".java",
		".php", ".scala", ".cs",
	} {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	return false
}

// Features is comments only. The jobs that need declarations or test bodies
// are skipped with a logged reason rather than served a guess.
func (Heuristic) Features() Features { return FeatComments }

// Change appends the comment lines the added lines introduce, keeping block
// comments whole across their lines.
func (g Heuristic) Change(root, rev string, c *Change, added map[string][]int) error {
	for _, name := range c.Files {
		if !g.Covers(name) {
			continue
		}
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		c.Comments = append(c.Comments, commentProse(source, name, added[name])...)
	}
	return nil
}

// commentProse lifts the comment lines among the added ones out of a source
// file by the prefixes the C-family shares: // and # for line comments, an
// open /* kept whole until its close. The shebang is not a comment.
func commentProse(source []byte, name string, touched []int) []Located {
	lines := strings.Split(string(source), "\n")
	if len(touched) == 0 {
		return nil
	}
	isTouched := map[int]bool{}
	for _, line := range touched {
		isTouched[line] = true
	}
	var out []Located
	inBlock := false
	for i, line := range lines {
		number := i + 1
		trimmed := strings.TrimSpace(line)
		switch {
		case inBlock:
			if isTouched[number] {
				t := strings.TrimSuffix(trimmed, "*/")
				t = strings.TrimSpace(strings.TrimPrefix(t, "*"))
				if t != "" {
					out = append(out, Located{Text: t, File: name, Line: number})
				}
			}
			if strings.Contains(trimmed, "*/") {
				inBlock = false
			}
		case strings.HasPrefix(trimmed, "/*"):
			t := trimmed[2:]
			if end := strings.Index(t, "*/"); end >= 0 {
				t = t[:end]
				if isTouched[number] && strings.TrimSpace(t) != "" {
					out = append(out, Located{Text: strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(t), "*")), File: name, Line: number})
				}
			} else {
				if isTouched[number] && strings.TrimSpace(t) != "" {
					out = append(out, Located{Text: strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(t), "*")), File: name, Line: number})
				}
				inBlock = true
			}
		case strings.HasPrefix(trimmed, "//"):
			if !isTouched[number] {
				continue
			}
			out = append(out, Located{
				Text: strings.TrimSpace(strings.TrimPrefix(trimmed, "//")),
				File: name, Line: number,
			})
		case strings.HasPrefix(trimmed, "#") && !strings.HasPrefix(trimmed, "#!"):
			if !isTouched[number] {
				continue
			}
			out = append(out, Located{
				Text: strings.TrimSpace(strings.TrimPrefix(trimmed, "#")),
				File: name, Line: number,
			})
		}
	}
	return out
}

// Whole is never asked: the heuristic declares no index.
func (Heuristic) Whole(root, rev string) ([]Declared, error) { return nil, nil }
