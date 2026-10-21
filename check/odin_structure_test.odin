package check

import "core:strings"
import "core:testing"

import "../change"

@(test)
odin_structure_reads_syntax_and_changed_lines :: proc(t: ^testing.T) {
	Case :: struct {
		name, path, src, other_path, other: string,
		lines:                              []int,
		rule:                               string,
	}
	cases := []Case {
		{
			"main outside cmd",
			"app/main.odin",
			"package main\nmain :: proc() {}\n",
			"",
			"",
			{1},
			"odin-main-location",
		},
		{
			"nested command",
			"cmd/tools/cli/main.odin",
			"package main\nmain :: proc() {}\n",
			"",
			"",
			{1},
			"",
		},
		{
			"cmd prefix is not subtree",
			"cmdline/main.odin",
			"package main\nmain :: proc() {}\n",
			"",
			"",
			{1},
			"odin-main-location",
		},
		{
			"unchanged package",
			"app/main.odin",
			"package main\nmain :: proc() {}\n",
			"",
			"",
			{2},
			"",
		},
		{
			"comment is not package",
			"domain/a.odin",
			"package domain\n// package main\n",
			"",
			"",
			{2},
			"",
		},
		{
			"two cli directories",
			"other/a.odin",
			"package cli\n",
			"cli/a.odin",
			"package cli\n",
			{1},
			"odin-cli-package",
		},
		{
			"two files one cli",
			"cli/b.odin",
			"package cli\n",
			"cli/a.odin",
			"package cli\n",
			{1},
			"",
		},
		{
			"aliased standard parser",
			"domain/a.odin",
			"package domain\nimport opts \"core:flags\"\nf :: proc() { opts.parse(nil, nil) }\n",
			"",
			"",
			{3},
			"odin-cli-parsing",
		},
		{
			"cli owns parsing",
			"cli/a.odin",
			"package cli\nimport \"core:flags\"\nf :: proc() { flags.parse(nil, nil) }\n",
			"",
			"",
			{3},
			"",
		},
		{
			"untouched parsing",
			"domain/a.odin",
			"package domain\nimport \"core:flags\"\nf :: proc() { flags.parse(nil, nil) }\n",
			"",
			"",
			{1},
			"",
		},
		{
			"types are not parsing",
			"domain/a.odin",
			"package domain\nimport \"core:flags\"\nx: flags.Parsing_Style\n",
			"",
			"",
			{3},
			"",
		},
		{
			"other parser",
			"domain/a.odin",
			"package domain\nimport flags \"core:json\"\nf :: proc() { flags.parse(nil, nil) }\n",
			"",
			"",
			{3},
			"",
		},
		{
			"shadowed import",
			"domain/a.odin",
			"package domain\nimport \"core:flags\"\nf :: proc(flags: Thing) { flags.parse(nil, nil) }\n",
			"",
			"",
			{3},
			"",
		},
		{
			"commented call",
			"domain/a.odin",
			"package domain\nimport \"core:flags\"\n// flags.parse(nil, nil)\n",
			"",
			"",
			{3},
			"",
		},
		{
			"deletion only",
			"app/main.odin",
			"package main\n",
			"cli/a.odin",
			"package cli\n",
			{},
			"",
		},
	}
	for k in cases {
		c := new(change.Change, context.temp_allocator)
		c.added = make(map[string][dynamic]change.Diff_Line, context.temp_allocator)
		added := make([dynamic]change.Diff_Line, context.temp_allocator)
		for line in k.lines {
			append(
				&added,
				change.Diff_Line {
					line,
					strings.split(k.src, "\n", context.temp_allocator)[line - 1],
				},
			)
		}
		c.added[k.path] = added
		sources := make(map[string][]byte, context.temp_allocator)
		sources[k.path] = transmute([]byte)k.src
		if k.other_path != "" {
			sources[k.other_path] = transmute([]byte)k.other
		}
		got := collect(
			Scope{c = c, sources = sources},
			check_odin_structure,
			context.temp_allocator,
		)
		want := 0 if k.rule == "" else 1
		testing.expectf(t, len(got) == want, "%s: got %v", k.name, got)
		if len(got) == 1 {
			testing.expect_value(t, got[0].rule, k.rule)
			testing.expect_value(t, got[0].line, k.lines[0])
		}
	}
}
