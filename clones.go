package main

// Two functions with the same body are one fact stated twice, and telling
// that two bodies are the same needs no judgement: the tokens either match
// or they do not. Whether two different bodies mean the same thing is the
// duplication job's; this is the part it should never have to be asked.

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

// The floors under which two bodies are not compared. Two one-line
// accessors are alike because accessors are alike, and saying so helps
// nobody; a copy of forty tokens is still a copy, but two small wrappers
// with the same shape — unmarshal, wrap the error, return — are the shape
// of wrappers, so a match in shape alone needs a body twice as long.
const (
	minCloneTokens = 40
	minShapeTokens = 80
)

// lexeme matches one lexical token of the C-family languages the tool
// reads: an identifier, a number, a string in any of three quotings, a
// two-character operator, or one character of punctuation.
var lexeme = regexp.MustCompile("[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9A-Fa-f]+|[0-9]+(?:\\.[0-9]+)?|\"(?:\\\\.|[^\"\\\\\n])*\"|'(?:\\\\.|[^'\\\\\n])*'|`[^`]*`|:=|::|==|!=|<=|>=|&&|\\|\\||\\+\\+|--|\\+=|-=|\\*=|/=|->|=>|<<|>>|\\S")

// comments matches what a tokeniser drops: line comments and block
// comments, in the shapes the tool's languages share.
var comments = regexp.MustCompile(`//[^\n]*|/\*[\s\S]*?\*/|(?m)^\s*#[^\n]*`)

// keywords are the words a language reserves, per grammar, which a
// structural comparison keeps while it replaces every other identifier.
var keywords = map[string]map[string]bool{
	"go": set(`break case chan const continue default defer else fallthrough for func go goto if import
		interface map package range return select struct switch type var nil true false iota
		len cap append make new panic recover error string int int8 int16 int32 int64 uint uint8 uint16
		uint32 uint64 byte rune float32 float64 bool any`),
	"js": set(`break case catch class const continue debugger default delete do else enum export extends
		false finally for function if import in instanceof new null return super switch this throw true
		try typeof var void while with yield let static async await of undefined interface type
		implements private public protected readonly declare namespace abstract as is keyof never
		unknown string number boolean object symbol bigint`),
	"py": set(`False None True and as assert async await break class continue def del elif else except
		finally for from global if import in is lambda nonlocal not or pass raise return try while with
		yield self cls print len range str int float list dict set tuple bool`),
	"rs": set(`as async await break const continue crate dyn else enum extern false fn for if impl in let
		loop match mod move mut pub ref return self Self static struct super trait true type unsafe use
		where while Some None Ok Err Vec String Option Result Box i8 i16 i32 i64 u8 u16 u32 u64 usize
		isize f32 f64 bool char str`),
	"odin": set(`package import foreign proc struct union enum bit_set map dynamic using if else when for
		switch case in not_in defer return break continue fallthrough cast transmute auto_cast distinct
		matrix or_else or_return or_break or_continue where do context true false nil int uint bool
		string rune byte f32 f64 i8 i16 i32 i64 u8 u16 u32 u64 uintptr rawptr any typeid`),
}

func set(words string) map[string]bool {
	out := map[string]bool{}
	for _, w := range strings.Fields(words) {
		out[w] = true
	}
	return out
}

// grammarFor is which keyword set a file's tokens are read with.
func grammarFor(path string) string {
	switch {
	case strings.HasSuffix(path, ".go"):
		return "go"
	case strings.HasSuffix(path, ".odin"):
		return "odin"
	case strings.HasSuffix(path, ".py"):
		return "py"
	case strings.HasSuffix(path, ".rs"):
		return "rs"
	case grammarOf(path) != "":
		return "js"
	}
	return filepath.Ext(path)
}

// shapes are a body's two normalisations: exact, with only the function's
// own name replaced, and structural, with every identifier and literal
// replaced. Empty when the body is too small to compare.
type shapes struct {
	exact, structural string
	tokens            int
}

// normalise reads a body into its shapes. Whitespace and comments are
// gone in both; the exact shape keeps every name but the function's own,
// the structural shape keeps only the grammar's keywords and punctuation.
func normalise(body, name, grammar string) shapes {
	stripped := comments.ReplaceAllString(body, " ")
	toks := lexeme.FindAllString(stripped, -1)
	if len(toks) < minCloneTokens {
		return shapes{}
	}
	reserved := keywords[grammar]
	exact := make([]string, len(toks))
	structural := make([]string, len(toks))
	for i, t := range toks {
		exact[i] = t
		if t == name {
			exact[i] = "NAME"
		}
		switch {
		case reserved[t]:
			structural[i] = t
		case t[0] == '_' || (t[0] >= 'a' && t[0] <= 'z') || (t[0] >= 'A' && t[0] <= 'Z'):
			structural[i] = "ID"
		case t[0] == '"' || t[0] == '\'' || t[0] == '`' || (t[0] >= '0' && t[0] <= '9'):
			structural[i] = "LIT"
		default:
			structural[i] = t
		}
	}
	return shapes{exact: strings.Join(exact, " "), structural: strings.Join(structural, " "), tokens: len(toks)}
}

// owned is one function with its shapes, and where it is declared.
type owned struct {
	name, file string
	line       int
	shape      shapes
}

// checkClones reports a new function whose body already exists: in the
// repository's index, or in another function the same change adds. An
// exact match is one function written twice and is must-fix; a match in
// shape alone, every name changed, is the same procedure over other
// names, and is worth considering.
func checkClones(c *Change) []Finding {
	var fresh []owned
	for _, s := range c.Symbols {
		if s.Kind != "func" || s.Body == "" || isTestFile(s.File) {
			continue
		}
		shape := normalise(s.Body, s.Name, grammarFor(s.File))
		if shape.tokens == 0 {
			continue
		}
		fresh = append(fresh, owned{s.Name, s.File, s.Line, shape})
	}
	if len(fresh) == 0 {
		return nil
	}
	var existing []owned
	for _, d := range c.index {
		if d.Kind != "func" || d.Body == "" {
			continue
		}
		shape := normalise(d.Body, d.Name, grammarFor(d.File))
		if shape.tokens == 0 {
			continue
		}
		existing = append(existing, owned{d.Name, d.File, d.Line, shape})
	}
	var out []Finding
	reported := map[string]bool{}
	report := func(a, b owned, exact bool) {
		key := fmt.Sprintf("%s:%d|%s:%d", a.file, a.line, b.file, b.line)
		if reported[key] {
			return
		}
		reported[key] = true
		how, severity := "the same body, token for token,", MustFix
		if !exact {
			how, severity = "the same shape of body, every name changed,", Consider
		}
		out = append(out, Finding{
			Job: "static", Rule: "duplicate-body", Severity: severity,
			File: a.file, Line: a.line, Symbol: a.name,
			Message: fmt.Sprintf("%s has %s as %s at %s:%d; one procedure written twice drifts into two", a.name, how, b.name, b.file, b.line),
			Fix:     fmt.Sprintf("call %s, or lift what they share into one function both call", b.name),
		})
	}
	for _, a := range fresh {
		for _, b := range existing {
			if a.file == b.file && a.line == b.line {
				continue
			}
			alike(a, b, report)
		}
	}
	// Two new functions alike are reported once, the later against the
	// earlier, where the index did not already hold the earlier.
	for i, a := range fresh {
		for _, b := range fresh[:i] {
			key := fmt.Sprintf("%s:%d|%s:%d", a.file, a.line, b.file, b.line)
			if reported[key] {
				continue
			}
			alike(a, b, report)
		}
	}
	return out
}

// alike reports a and b to the caller when their bodies match: exactly at
// any size compared, or in shape when both are long enough for a shape to
// mean something.
func alike(a, b owned, report func(a, b owned, exact bool)) {
	switch {
	case a.shape.exact == b.shape.exact:
		report(a, b, true)
	case a.shape.tokens >= minShapeTokens && b.shape.tokens >= minShapeTokens && a.shape.structural == b.shape.structural:
		report(a, b, false)
	}
}
