package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// TSFrontend reads TypeScript and JavaScript through ast-grep, which
// matches its patterns against the tree-sitter syntax tree rather than
// against lines. A pattern over lines misses an indented constant inside a
// block; a query over syntax does not, and the top-level constraint keeps
// function bodies out.
type TSFrontend struct{}

func (TSFrontend) Name() string { return "typescript" }

func (TSFrontend) Covers(path string) bool {
	return grammarOf(path) != ""
}

// grammarOf is the ast-grep grammar a path is parsed with, or empty where
// none of this frontend's grammars reads it.
func grammarOf(path string) string {
	switch filepath.Ext(path) {
	case ".ts":
		return "ts"
	case ".tsx":
		return "tsx"
	case ".js", ".jsx", ".mjs", ".cjs":
		return "js"
	}
	return ""
}

// scratchExt is the extension a file is materialised under, which is what
// ast-grep infers the grammar from. The module variants of JavaScript are
// the same grammar under another name.
func scratchExt(path string) string {
	switch ext := filepath.Ext(path); ext {
	case ".mjs", ".cjs":
		return ".js"
	default:
		return ext
	}
}

// typed is whether a pattern needs TypeScript's grammar: an annotation, an
// interface, a type alias or an enum is not JavaScript.
func typed(pattern string) bool {
	return strings.Contains(pattern, ": $$$") || strings.HasPrefix(strings.TrimPrefix(pattern, "export "), "type ") ||
		strings.Contains(pattern, "interface ") || strings.Contains(pattern, "enum ")
}

func (TSFrontend) Features() Features {
	return FeatSymbols | FeatTests | FeatComments | FeatIndex
}

// tsPatterns is the set of top-level declarations the queries bind. Export
// status is part of the pattern so a symbol's audience is known to the jobs;
// the plain forms also match the inner node of an export, which the
// gatherer resolves by preferring the exported match.
var tsPatterns = []struct {
	kind     string
	exported bool
	pattern  string
}{
	{"value", false, "const $N = $$$V"},
	{"value", true, "export const $N = $$$V"},
	{"value", false, "const $N: $$$T = $$$V"},
	{"value", true, "export const $N: $$$T = $$$V"},
	{"value", false, "let $N = $$$V"},
	{"value", true, "export let $N = $$$V"},
	{"value", true, "export let $N: $$$T = $$$V"},
	{"value", false, "var $N = $$$V"},
	{"value", true, "export var $N = $$$V"},
	{"type", false, "type $N = $$$B"},
	{"type", true, "export type $N = $$$B"},
	{"type", false, "interface $N { $$$B }"},
	{"type", true, "export interface $N { $$$B }"},
	{"type", false, "enum $N { $$$V }"},
	{"type", true, "export enum $N { $$$V }"},
	{"type", false, "class $N { $$$B }"},
	{"type", true, "export class $N { $$$B }"},
	{"func", false, "function $N($$$P) { $$$B }"},
	{"func", true, "export function $N($$$P) { $$$B }"},
	{"func", true, "export function $N($$$P): $$$R { $$$B }"},
	{"func", false, "async function $N($$$P) { $$$B }"},
	{"func", true, "export async function $N($$$P) { $$$B }"},
	{"func", true, "export async function $N($$$P): $$$R { $$$B }"},
	{"func", true, "export default function $N($$$P) { $$$B }"},
	{"func", true, "export default function $N($$$P): $$$R { $$$B }"},
}

// tsTestPatterns bind the runner's calls, in the shapes Node's node:test,
// Bun's bun:test, Deno's Deno.test and the Jest family write them: the bare
// call, a modifier such as skip, only, ignore or fails, a table through
// each, Deno's object and named-function forms. A test inside a describe
// block is still a test, so these carry no top-level constraint; they are
// only ever asked for, so a helper named test would not distract them
// elsewhere. The name is $S when the test is named by a string and $N when
// by a function.
var tsTestPatterns = []string{
	"test($S, $$$B)", "it($S, $$$B)",
	"test.$M($S, $$$B)", "it.$M($S, $$$B)",
	"test.$M($$$T)($S, $$$B)", "it.$M($$$T)($S, $$$B)",
	"Deno.test($S, $$$B)", "Deno.test.$M($S, $$$B)",
	"Deno.test({ name: $S, $$$R })",
	"Deno.test(function $N($$$P) { $$$B })",
}

// grepMatch is one ast-grep finding.
type grepMatch struct {
	Rule  string `json:"ruleId"`
	Text  string `json:"text"`
	File  string `json:"file"`
	Range struct {
		Start struct {
			Line int `json:"line"`
		} `json:"start"`
	} `json:"range"`
	Meta struct {
		Single map[string]struct {
			Text string `json:"text"`
		} `json:"single"`
	} `json:"metaVariables"`
}

func (m grepMatch) name() string {
	for _, key := range []string{"N", "S"} {
		if bound, ok := m.Meta.Single[key]; ok {
			return bound.Text
		}
	}
	return ""
}

// scan materialises the files at the revision into a scratch directory
// (ast-grep reads the working tree, and a review is a change, not a tree),
// writes the rules, and asks for the matches. The returned matches carry the
// scratch path in File; the caller maps it back through the order given.
func scan(files []string, root, rev string) ([]grepMatch, error) {
	return scanWith(files, root, rev, writeRules)
}

// scanWith is scan for any grammar: the rules written are the caller's.
func scanWith(files []string, root, rev string, rules func(dir string) error) ([]grepMatch, error) {
	if len(files) == 0 {
		return nil, nil
	}
	dir, err := os.MkdirTemp("", "review-ts")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)

	if err := os.MkdirAll(filepath.Join(dir, "rules"), 0o755); err != nil {
		return nil, err
	}
	config := "ruleDirs:\n  - rules\n"
	if err := os.WriteFile(filepath.Join(dir, "sgconfig.yml"), []byte(config), 0o644); err != nil {
		return nil, err
	}
	if err := rules(filepath.Join(dir, "rules")); err != nil {
		return nil, err
	}

	var args []string
	for i, name := range files {
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		// The extension is kept: ast-grep infers the grammar from it.
		scratch := filepath.Join(dir, fmt.Sprintf("%04d%s", i, scratchExt(name)))
		if err := os.WriteFile(scratch, source, 0o644); err != nil {
			return nil, err
		}
		args = append(args, scratch)
	}
	cmd := exec.Command("ast-grep", append([]string{"scan", "-c", filepath.Join(dir, "sgconfig.yml"), "--json"}, args...)...)
	stdout, err := cmd.Output()
	if err != nil && len(stdout) == 0 {
		return nil, err // A clean failure; anything else is partial output to read.
	}
	var out []grepMatch
	if err := json.Unmarshal(stdout, &out); err != nil {
		return nil, fmt.Errorf("ast-grep: %w", err)
	}
	for i := range out {
		base := strings.TrimSuffix(filepath.Base(out[i].File), filepath.Ext(out[i].File))
		index, err := strconv.Atoi(base)
		if err == nil && index < len(files) {
			out[i].File = files[index]
		}
	}
	return out, nil
}

// writeRules emits the query set for both grammars. The top-level rule keeps
// declarations out of function bodies; the test rules go anywhere.
func writeRules(dir string) error {
	top := func(pattern string) string {
		return fmt.Sprintf("pattern: %q\nnot:\n  inside:\n    kind: statement_block\n    stopBy: end\n", pattern)
	}
	for _, table := range []struct {
		prefix   string
		language string
		patterns []struct {
			kind     string
			exported bool
			pattern  string
		}
	}{{"ts", "TypeScript", tsPatterns}, {"tsx", "TSX", tsPatterns}, {"js", "JavaScript", tsPatterns}} {
		for i, p := range table.patterns {
			if table.prefix == "js" && typed(p.pattern) {
				continue
			}
			status := "plain"
			if p.exported {
				status = "export"
			}
			id := fmt.Sprintf("%s-%s-%s-%d", table.prefix, p.kind, status, i)
			body := fmt.Sprintf("id: %s\nlanguage: %s\nseverity: info\nrule:\n  %s", id, table.language, strings.ReplaceAll(top(p.pattern), "\n", "\n  "))
			if err := os.WriteFile(filepath.Join(dir, id+".yml"), []byte(body), 0o644); err != nil {
				return err
			}
		}
	}
	for _, table := range []struct {
		prefix   string
		language string
	}{{"ts", "TypeScript"}, {"tsx", "TSX"}, {"js", "JavaScript"}} {
		for i, pattern := range tsTestPatterns {
			id := fmt.Sprintf("%s-test-%d", table.prefix, i)
			body := fmt.Sprintf("id: %s\nlanguage: %s\nseverity: info\nrule:\n  pattern: %q\n", id, table.language, pattern)
			if err := os.WriteFile(filepath.Join(dir, id+".yml"), []byte(body), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

// Change appends the declarations, tests and prose the added lines of the
// change's TypeScript files introduce.
func (g TSFrontend) Change(root, rev string, c *Change, added map[string][]int) error {
	var covered []string
	for _, name := range c.Files {
		if g.Covers(name) {
			covered = append(covered, name)
		}
	}
	matches, err := scan(covered, root, rev)
	if err != nil {
		return err
	}
	sources := map[string][]byte{}
	lines := map[string][]string{}
	touched := map[string]map[int]bool{}
	for _, name := range covered {
		source, err := at(root, rev, name)
		if err != nil {
			continue
		}
		sources[name] = source
		lines[name] = strings.Split(string(source), "\n")
		touched[name] = map[int]bool{}
		for _, line := range added[name] {
			touched[name][line] = true
		}
	}

	// One declaration, several matches: the plain forms see the inner node of
	// an export. Keep the exported reading of each line.
	best := map[string]grepMatch{}
	for _, m := range matches {
		key := m.File + ":" + fmt.Sprint(m.Range.Start.Line)
		old, ok := best[key]
		if !ok || (strings.Contains(m.Rule, "export") && !strings.Contains(old.Rule, "export")) {
			best[key] = m
		}
	}
	for _, m := range ordered(best) {
		if strings.Contains(m.Rule, "-test-") {
			name := unquote(m.name())
			if name == "" || !touched[m.File][m.Range.Start.Line+1] {
				continue
			}
			c.Tests = append(c.Tests, Function{
				Name: name, File: m.File, Line: m.Range.Start.Line + 1, Body: m.Text,
			})
			continue
		}
		name := m.name()
		if name == "" || !touched[m.File][m.Range.Start.Line+1] {
			continue
		}
		line := m.Range.Start.Line + 1
		signature := ""
		if line-1 < len(lines[m.File]) {
			signature = strings.TrimSpace(lines[m.File][line-1])
		}
		symbol := Symbol{
			Name: name, Kind: ruleKind(m.Rule), Doc: docAbove(lines[m.File], line),
			File: m.File, Line: line,
			Exported:  strings.Contains(m.Rule, "export"),
			Signature: signature,
		}
		if symbol.Kind == "func" {
			symbol.Body = m.Text
		}
		c.Symbols = append(c.Symbols, symbol)
	}
	for _, name := range covered {
		c.Comments = append(c.Comments, commentProse(sources[name], name, added[name])...)
	}
	return nil
}

// Whole reads every top-level declaration in the repository's TypeScript
// files, so a new name can be checked against the ones it may duplicate.
func (g TSFrontend) Whole(root, rev string) ([]Declared, error) {
	tree, err := treeAt(root, rev)
	if err != nil {
		return nil, err
	}
	tracked, err := tree.Files()
	if err != nil {
		return nil, err
	}
	var files []string
	for _, name := range tracked {
		if g.Covers(name) {
			files = append(files, name)
		}
	}
	matches, err := scan(files, root, rev)
	if err != nil {
		return nil, err
	}
	best := map[string]grepMatch{}
	for _, m := range matches {
		key := m.File + ":" + fmt.Sprint(m.Range.Start.Line)
		old, ok := best[key]
		if !ok || (strings.Contains(m.Rule, "export") && !strings.Contains(old.Rule, "export")) {
			best[key] = m
		}
	}
	var index []Declared
	for _, m := range ordered(best) {
		name := m.name()
		if name == "" || strings.Contains(m.Rule, "-test-") {
			continue
		}
		line := m.Range.Start.Line + 1
		text := ""
		if source, err := at(root, rev, m.File); err == nil {
			fileLines := strings.Split(string(source), "\n")
			if line-1 < len(fileLines) {
				text = fileLines[line-1]
			}
		}
		declared := Declared{Name: name, Kind: ruleKind(m.Rule), File: m.File, Line: line, Text: text}
		if declared.Kind == "func" {
			declared.Body = m.Text
		}
		index = append(index, declared)
	}
	return index, nil
}

// ordered is the best matches in file and line order, so that what is
// read from them — and the finding anchored on the first of them — is the
// same on every run.
func ordered(best map[string]grepMatch) []grepMatch {
	out := make([]grepMatch, 0, len(best))
	for _, m := range best {
		out = append(out, m)
	}
	slices.SortFunc(out, func(a, b grepMatch) int {
		if c := strings.Compare(a.File, b.File); c != 0 {
			return c
		}
		return a.Range.Start.Line - b.Range.Start.Line
	})
	return out
}

// ruleKind turns a rule id back into the shape the findings report.
func ruleKind(rule string) string {
	switch {
	case strings.Contains(rule, "-func-"):
		return "func"
	case strings.Contains(rule, "-type-"):
		return "type"
	}
	return "value"
}

// docAbove collects the comment block ending on the line before the
// declaration, as the doc a reader would attach to it, in the C-family
// shapes and Python's.
func docAbove(lines []string, line int) string {
	var parts []string
	for i := line - 2; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(trimmed, "//") && !strings.HasPrefix(trimmed, "*") && !strings.HasPrefix(trimmed, "/*") &&
			(!strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "#!")) {
			break
		}
		trimmed = strings.TrimPrefix(trimmed, "#")
		trimmed = strings.TrimPrefix(trimmed, "///")
		trimmed = strings.TrimPrefix(trimmed, "//")
		trimmed = strings.TrimPrefix(trimmed, "/**")
		trimmed = strings.TrimPrefix(trimmed, "/*")
		trimmed = strings.TrimSuffix(trimmed, "*/")
		part := strings.TrimSpace(strings.TrimPrefix(trimmed, "*"))
		if part != "" {
			parts = append([]string{part}, parts...)
		}
	}
	return strings.Join(parts, " ")
}

// unquote strips the quotes a string literal keeps in its text.
func unquote(literal string) string {
	return strings.Trim(literal, "\"'`")
}
