package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// TSFrontend reads TypeScript through ast-grep, which matches its patterns
// against the tree-sitter syntax tree rather than against lines. A pattern
// over lines misses an indented constant inside a block; a query over syntax
// does not, and the top-level constraint keeps function bodies out.
type TSFrontend struct{}

func (TSFrontend) Name() string { return "typescript" }

func (TSFrontend) Covers(path string) bool {
	return strings.HasSuffix(path, ".ts") || strings.HasSuffix(path, ".tsx")
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

// tsTestPatterns bind the runner's calls. A test inside a describe block is
// still a test, so these carry no top-level constraint; they are only ever
// asked for, so a helper named test would not distract them elsewhere.
var tsTestPatterns = []string{"test($S, $$$B)", "it($S, $$$B)"}

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
	if err := writeRules(filepath.Join(dir, "rules")); err != nil {
		return nil, err
	}

	var args []string
	for i, name := range files {
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		// The extension is kept: ast-grep infers the grammar from it.
		scratch := filepath.Join(dir, fmt.Sprintf("%04d%s", i, filepath.Ext(name)))
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
	}{{"ts", "TypeScript", tsPatterns}, {"tsx", "TSX", tsPatterns}} {
		for i, p := range table.patterns {
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
	}{{"ts", "TypeScript"}, {"tsx", "TSX"}} {
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
	for _, m := range best {
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
		c.Symbols = append(c.Symbols, Symbol{
			Name: name, Kind: ruleKind(m.Rule), Doc: docAbove(lines[m.File], line),
			File: m.File, Line: line,
			Exported:  strings.Contains(m.Rule, "export"),
			Signature: signature,
		})
	}
	for _, name := range covered {
		c.Comments = append(c.Comments, commentProse(sources[name], name, added[name])...)
	}
	return nil
}

// Whole reads every top-level declaration in the repository's TypeScript
// files, so a new name can be checked against the ones it may duplicate.
func (g TSFrontend) Whole(root, rev string) ([]Declared, error) {
	out, err := git(root, "ls-files", "*.ts", "*.tsx")
	if err != nil {
		return nil, err
	}
	var files []string
	for _, name := range strings.Split(strings.TrimSpace(out), "\n") {
		if name != "" && g.Covers(name) {
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
	for _, m := range best {
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
		index = append(index, Declared{Name: name, Kind: ruleKind(m.Rule), File: m.File, Line: line, Text: text})
	}
	return index, nil
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
// declaration, as the doc a reader would attach to it.
func docAbove(lines []string, line int) string {
	var parts []string
	for i := line - 2; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(trimmed, "//") && !strings.HasPrefix(trimmed, "*") && !strings.HasPrefix(trimmed, "/*") {
			break
		}
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
