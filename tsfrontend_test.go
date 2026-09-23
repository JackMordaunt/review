package main

import (
	"os/exec"
	"slices"
	"strings"
	"testing"
)

// The TypeScript tests hold the frontend against ast-grep's parsing, an
// external authority: when it is absent they fail, they do not skip.
func needAstGrep(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ast-grep"); err != nil {
		t.Fatalf("ast-grep is not installed: %v", err)
	}
}

func TestTypeScriptReadsDeclarations(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/icons.ts", `export const maxIcons: number = 12;
const hidden = 4;
export function readIcons(src: string): Group[] { return []; }
export default function load(src: string) { return src; }
export class Reader { size = 0; }
export interface Wide {}
export type Group = { id: number };
export enum Kind { Small = 1 }
function helper() { return hidden; }
`)
	r.write("src/.keep", "")
	r.commit("ts: begin", "src/.keep")
	rev := r.commit("ts: first", "src/icons.ts")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Symbol{}
	for _, s := range change.Symbols {
		got[s.Name] = s
	}
	for name, want := range map[string]struct {
		kind     string
		exported bool
	}{
		"maxIcons":  {"value", true},
		"hidden":    {"value", false},
		"readIcons": {"func", true},
		"load":      {"func", true},
		"Reader":    {"type", true},
		"Wide":      {"type", true},
		"Group":     {"type", true},
		"Kind":      {"type", true},
		"helper":    {"func", false},
	} {
		s, ok := got[name]
		if !ok {
			t.Errorf("%s not read", name)
			continue
		}
		if s.Kind != want.kind || s.Exported != want.exported {
			t.Errorf("%s: got %s exported=%v, want %s exported=%v", name, s.Kind, s.Exported, want.kind, want.exported)
		}
		if !strings.HasPrefix(s.Signature, name) && !strings.Contains(s.Signature, name) {
			t.Errorf("%s: signature %q", name, s.Signature)
		}
	}
}

func TestTypeScriptReadsTestsInsideDescribe(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/icons.test.ts", `import {test, expect} from 'vitest';

describe('icons', () => {
  it('decodes the largest', () => {
    expect(1).toBe(1);
  });
  test('reads a binary', () => {
    expect(2).toBe(2);
  });
});
`)
	r.write("src/.keep", "")
	r.commit("ts: begin", "src/.keep")
	rev := r.commit("ts: tests", "src/icons.test.ts")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, test := range change.Tests {
		names = append(names, test.Name)
		if !strings.Contains(test.Body, "expect") {
			t.Errorf("%s: body %q has no assertion", test.Name, test.Body)
		}
	}
	if len(names) != 2 {
		t.Fatalf("tests %v, want the it and the test", names)
	}
	for _, want := range []string{"decodes the largest", "reads a binary"} {
		if !slices.Contains(names, want) {
			t.Errorf("tests %v, want %q among them", names, want)
		}
	}
}

func TestTypeScriptReadsEveryRunnersTests(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/deno_test.ts", `import { assertEquals } from "@std/assert";
Deno.test("deno string", () => { assertEquals(1, 1); });
Deno.test({ name: "deno object", fn() { assertEquals(2, 2); } });
Deno.test(function denoNamed() { assertEquals(3, 3); });
Deno.test.ignore("deno ignored", () => { assertEquals(4, 4); });
`)
	r.write("src/bun.test.ts", `import { test, it, expect } from "bun:test";
test.skip("bun skipped", () => { expect(1).toBe(1); });
it.only("bun focused", () => { expect(1).toBe(1); });
test.each([[1]])("bun each %i", (a) => { expect(a).toBe(1); });
test("bun plain", async () => { expect(1).toBe(1); });
`)
	r.write("src/node.test.js", `import { test } from "node:test";
import assert from "node:assert";
test("node plain", { timeout: 5 }, () => { assert.equal(1, 1); });
test.todo("node todo", () => { assert.ok(true); });
`)
	r.write("src/.keep", "")
	r.commit("ts: begin", "src/.keep")
	rev := r.commit("ts: tests", "src/deno_test.ts", "src/bun.test.ts", "src/node.test.js")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, test := range change.Tests {
		names = append(names, test.Name)
	}
	want := []string{
		"deno string", "deno object", "denoNamed", "deno ignored",
		"bun skipped", "bun focused", "bun each %i", "bun plain",
		"node plain", "node todo",
	}
	for _, w := range want {
		if !slices.Contains(names, w) {
			t.Errorf("tests %v, want %q among them", names, w)
		}
	}
	if len(names) != len(want) {
		t.Errorf("tests %v: %d, want %d", names, len(names), len(want))
	}
}

func TestTypeScriptReadsDocComments(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/icons.ts", `/** Counts the icons a binary carries.
 *  Rejects a binary with none.
 */
export function countIcons(): number { return 0; }
`)
	r.write("src/.keep", "")
	r.commit("ts: begin", "src/.keep")
	rev := r.commit("ts: count", "src/icons.ts")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	if len(change.Symbols) != 1 {
		t.Fatalf("symbols %v", change.Symbols)
	}
	want := "Counts the icons a binary carries. Rejects a binary with none."
	if change.Symbols[0].Doc != want {
		t.Errorf("doc %q, want %q", change.Symbols[0].Doc, want)
	}
	if len(change.Comments) != 2 {
		t.Fatalf("comments %v, want both comment lines", change.Comments)
	}
	if change.Comments[0].Text != "Counts the icons a binary carries." {
		t.Errorf("comments[0] %q", change.Comments[0].Text)
	}
	if change.Comments[1].Text != "Rejects a binary with none." {
		t.Errorf("comments[1] %q", change.Comments[1].Text)
	}
}

func TestTypeScriptIndexesTheRepository(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/a.ts", `export const plain = 3;
const hidden = 4;
export class Sized { size = 0; }
function local() {}
`)
	r.write("src/a.test.ts", `test('local is not a fact with two owners', () => {});
`)
	r.write("src/.keep", "")
	r.commit("ts: begin", "src/.keep")
	rev := r.commit("ts: index", "src/a.ts", "src/a.test.ts")

	declared, err := TSFrontend{}.Whole(r.Root, rev)
	if err != nil {
		t.Fatal(err)
	}
	index := map[string]Declared{}
	for _, d := range declared {
		if _, dup := index[d.Name]; dup {
			t.Errorf("%s indexed twice", d.Name)
		}
		index[d.Name] = d
	}
	if d, ok := index["plain"]; !ok || d.Text != "export const plain = 3;" {
		t.Errorf("plain %v", d)
	}
	if d, ok := index["hidden"]; !ok || d.Text != "const hidden = 4;" {
		t.Errorf("hidden %v", d)
	}
	if d, ok := index["Sized"]; !ok || d.Text != "export class Sized { size = 0; }" {
		t.Errorf("Sized %v", d)
	}
	if _, ok := index["local"]; !ok {
		t.Error("local not indexed")
	}
	if d, ok := index["local"]; ok && d.Text != "function local() {}" {
		t.Errorf("local text %q", d.Text)
	}
	for name := range index {
		if strings.Contains(name, "owners") {
			t.Errorf("test file name %s indexed", name)
		}
	}
}

// JavaScript is the same grammar without the types, and reads through the
// same frontend: declarations, tests and bodies.
func TestJavaScriptReadsDeclarations(t *testing.T) {
	needAstGrep(t)
	r := newRepo(t)
	r.write("src/.keep", "")
	r.commit("js: begin", "src/.keep")
	r.write("src/icons.js", `export const maxIcons = 12;
const hidden = 4;
export function readIcons(src) { return []; }
function helper() { return hidden; }
`)
	r.write("src/icons.test.js", `test('reads icons', () => { expect(readIcons('x')).toEqual([]); });
`)
	r.write("src/app.jsx", `export function App() { return <div/>; }
`)
	rev := r.commit("js: first", "src/icons.js", "src/icons.test.js", "src/app.jsx")

	change, err := Gather(rev+"^.."+rev, r.Root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Symbol{}
	for _, s := range change.Symbols {
		got[s.Name] = s
	}
	for name, want := range map[string]struct {
		kind     string
		exported bool
	}{
		"maxIcons":  {"value", true},
		"hidden":    {"value", false},
		"readIcons": {"func", true},
		"helper":    {"func", false},
		"App":       {"func", true},
	} {
		s, ok := got[name]
		if !ok {
			t.Errorf("%s not read", name)
			continue
		}
		if s.Kind != want.kind || s.Exported != want.exported {
			t.Errorf("%s: got %s exported=%v, want %s exported=%v", name, s.Kind, s.Exported, want.kind, want.exported)
		}
	}
	if got["readIcons"].Body == "" {
		t.Error("a function's body was not read")
	}
	if len(change.Tests) != 1 || change.Tests[0].Name != "reads icons" {
		t.Errorf("tests: %v", change.Tests)
	}
	if len(change.Uncovered) != 0 {
		t.Errorf("uncovered: %v", change.Uncovered)
	}
}
