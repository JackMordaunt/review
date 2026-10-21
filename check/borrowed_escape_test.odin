package check

import "core:strings"
import "core:testing"

import "../finding"

@(test)
borrowed_escape_reports :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		src:   string,
		lines: []int,
		want:  []int,
		text:  string,
	}
	cases := []Case {
		{
			"pure conversion of an addressed header",
			"package a\nf :: proc() -> string {\n buf: [4]u8\n s := buf[:]\n p := &s\n return string(s)\n}",
			{6}, {6}, "aliased",
		},
		{
			"pointer alias passed to a helper",
			"package a\nf :: proc() -> []u8 {\n buf: [4]u8\n s := buf[:]\n p := &s\n replace(p)\n return s\n}",
			{7}, nil, "",
		},
		{
			"address taken before borrowed assignment",
			"package a\nf :: proc() -> []u8 {\n buf: [4]u8\n s: []u8\n p := &s\n s = buf[:]\n p^ = make([]u8, 4)\n return s\n}",
			{8}, nil, "",
		},
		{
			"address taken before helper mutation",
			"package a\nf :: proc() -> []u8 {\n buf: [4]u8\n s: []u8\n p := &s\n s = buf[:]\n replace(p)\n return s\n}",
			{8}, nil, "",
		},
		{
			"direct slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\treturn buf[:]\n}",
			{4},
			{4},
			"slice",
		},
		{
			"alias then return",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\treturn s\n}",
			{5},
			{5},
			"slice",
		},
		{
			"string conversion",
			"package a\nf :: proc() -> string {\n\tbuf: [4]u8\n\treturn string(buf[:])\n}",
			{4},
			{4},
			"aliased",
		},
		{
			"string of a local slice",
			"package a\nf :: proc() -> string {\n\tbuf: [4]u8\n\ts := buf[:]\n\treturn string(s)\n}",
			{5},
			{5},
			"aliased",
		},
		{
			"stored string alias",
			"package a\nf :: proc() -> string {\n\tbuf: [4]u8\n\ts := string(buf[:])\n\treturn s\n}",
			{5},
			{5},
			"aliased",
		},
		{
			"transmute",
			"package a\nf :: proc() -> string {\n\tbuf: [4]u8\n\treturn transmute(string)(buf[:])\n}",
			{4},
			{4},
			"aliased",
		},
		{
			"cast of a local slice",
			"package a\nf :: proc() -> string {\n\tbuf: [4]byte\n\ts := buf[:]\n\treturn cast(string)s\n}",
			{5},
			{5},
			"aliased",
		},
		{
			"named result",
			"package a\nf :: proc() -> (out: []u8) {\n\tbuf: [4]u8\n\tout = buf[:]\n\treturn\n}",
			{5},
			{5},
			"slice",
		},
		{
			"assignment is the added line",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts: []u8\n\ts = buf[:]\n\treturn s\n}",
			{5},
			{5},
			"slice",
		},
		{
			"inline element",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [2][4]u8\n\treturn buf[0][:]\n}",
			{4},
			{4},
			"slice",
		},
		{
			"fixed capacity dynamic array",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [dynamic; 4]u8\n\ts := buf[:]\n\treturn s\n}",
			{5},
			{5},
			"slice",
		},
		{
			"array literal",
			"package a\nf :: proc() -> []u8 {\n\treturn ([4]u8{1, 2, 3, 4})[:]\n}",
			{3},
			{3},
			"temporary",
		},
		{
			"return inside if",
			"package a\nf :: proc(cond: bool) -> []u8 {\n\tbuf: [4]u8\n\tif cond {\n\t\treturn buf[:]\n\t}\n}",
			{5},
			{5},
			"slice",
		},
		{
			"branch does not assign",
			"package a\nf :: proc(cond: bool) -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tif cond {\n\t\tx := 1\n\t\t_ = x\n\t}\n\treturn s\n}",
			{9},
			{9},
			"slice",
		},
		{
			"defer runs after the return",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tdefer s = make([]u8, 4)\n\treturn s\n}",
			{6},
			{6},
			"slice",
		},
		{
			"range variable does not hide the outer slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tfor s in buf {\n\t\t_ = s\n\t}\n\treturn s\n}",
			{8},
			{8},
			"slice",
		},
		{
			"outer binding returns after an inner shadow",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\t{\n\t\tbuf := make([]u8, 4)\n\t\t_ = buf\n\t}\n\ts := buf[:]\n\treturn s\n}",
			{9},
			{9},
			"slice",
		},
		{
			"nested procedure has its own array",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\tg :: proc() -> []u8 {\n\t\tb: [4]u8\n\t\tt := b[:]\n\t\treturn t\n\t}\n\ts := buf[:]\n\t_ = g\n\treturn s\n}",
			{7, 11},
			{7, 11},
			"",
		},
		{
			"array returned by value",
			"package a\nf :: proc() -> [4]u8 {\n\tbuf: [4]u8\n\treturn buf\n}",
			{4},
			{},
			"",
		},
		{
			"make",
			"package a\nf :: proc() -> []u8 {\n\tbuf := make([]u8, 4)\n\treturn buf\n}",
			{4},
			{},
			"",
		},
		{
			"new",
			"package a\nf :: proc() -> []u8 {\n\tp := new([4]u8)\n\treturn p[:]\n}",
			{4},
			{},
			"",
		},
		{
			"dynamic array",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [dynamic]u8\n\treturn buf[:]\n}",
			{4},
			{},
			"",
		},
		{
			"package array",
			"package a\nbuf: [4]u8\nf :: proc() -> []u8 {\n\treturn buf[:]\n}",
			{4},
			{},
			"",
		},
		{
			"static local",
			"package a\nf :: proc() -> []u8 {\n\t@(static) buf: [4]u8\n\ts := buf[:]\n\treturn s\n}",
			{5},
			{},
			"",
		},
		{
			"strings.clone",
			"package a\nimport \"core:strings\"\nf :: proc() -> string {\n\tbuf: [4]u8\n\treturn strings.clone(string(buf[:]))\n}",
			{5},
			{},
			"",
		},
		{
			"copy into a heap slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\tdst := make([]u8, 4)\n\tcopy(dst, buf[:])\n\treturn dst\n}",
			{6},
			{},
			"",
		},
		{
			"unchanged return",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\treturn s\n}",
			{3},
			{},
			"",
		},
		{
			"file-level string shadow",
			"package a\nstring :: proc(s: []u8) -> string {\n\treturn \"copied\"\n}\nf :: proc() -> string {\n\tbuf: [4]u8\n\treturn string(buf[:])\n}",
			{7},
			{},
			"",
		},
		{
			"import alias shadows string",
			"package a\nimport string \"core:strings\"\nf :: proc() -> string {\n\tbuf: [4]u8\n\treturn string(buf[:])\n}",
			{5},
			{},
			"",
		},
		{
			"local string shadow",
			"package a\nf :: proc() -> string {\n\tstring :: proc(s: []u8) -> string {\n\t\treturn \"copied\"\n\t}\n\tbuf: [4]u8\n\treturn string(buf[:])\n}",
			{7},
			{},
			"",
		},
		{
			"parameter array",
			"package a\nf :: proc(buf: [4]u8) -> []u8 {\n\treturn buf[:]\n}",
			{3},
			{},
			"",
		},
		{
			"constant array",
			"package a\nf :: proc() -> []u8 {\n\tbuf :: [4]u8{1, 2, 3, 4}\n\treturn buf[:]\n}",
			{4},
			{},
			"",
		},
		{
			"conditional overwrite",
			"package a\nf :: proc(cond: bool) -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tif cond {\n\t\ts = make([]u8, 4)\n\t}\n\treturn s\n}",
			{8},
			{},
			"",
		},
		{
			"straight-line overwrite",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\ts = make([]u8, 4)\n\treturn s\n}",
			{6},
			{},
			"",
		},
		{
			"inner make shadows the array",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\t{\n\t\tbuf := make([]u8, 4)\n\t\treturn buf\n\t}\n}",
			{6},
			{},
			"",
		},
		{
			"outer make after an inner array",
			"package a\nf :: proc() -> []u8 {\n\tbuf := make([]u8, 4)\n\t{\n\t\tbuf: [4]u8\n\t\t_ = buf\n\t}\n\treturn buf\n}",
			{8},
			{},
			"",
		},
		{
			"nested procedure does not capture",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\tg :: proc() -> []u8 {\n\t\treturn buf[:]\n\t}\n\t_ = g\n\treturn nil\n}",
			{5, 8},
			{},
			"",
		},
		{
			"string of a non-byte slice",
			"package a\nf :: proc() -> string {\n\tbuf: [4]int\n\ts := buf[:]\n\treturn string(s)\n}",
			{5},
			{},
			"",
		},
		{
			"unknown callee",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\treturn sink(buf[:])\n}",
			{4},
			{},
			"",
		},
		{
			"ternary join",
			"package a\nf :: proc(cond: bool) -> []u8 {\n\tbuf: [4]u8\n\treturn cond ? buf[:] : make([]u8, 4)\n}",
			{4},
			{},
			"",
		},
		{
			"pointer local",
			"package a\nf :: proc() -> ^[4]u8 {\n\tbuf: [4]u8\n\tp := &buf\n\treturn p\n}",
			{5},
			{},
			"",
		},
		{
			"temp reset is not this rule",
			"package a\nimport \"core:fmt\"\nf :: proc() -> string {\n\ts := fmt.tprintf(\"%d\", 1)\n\tfree_all(context.temp_allocator)\n\treturn s\n}",
			{6},
			{},
			"",
		},
		{
			"named result cleared",
			"package a\nf :: proc() -> (out: []u8) {\n\tbuf: [4]u8\n\tout = buf[:]\n\tout = make([]u8, 4)\n\treturn\n}",
			{6},
			{},
			"",
		},
		{
			"call may repoint the slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\treplace(&s)\n\treturn s\n}",
			{6},
			{},
			"",
		},
		{
			"indirect store may repoint the slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tp := &s\n\tp^ = make([]u8, 4)\n\treturn s\n}",
			{7},
			{},
			"",
		},
		{
			"address taken, no write",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tp := &s\n\treturn s\n}",
			{6},
			{6},
			"slice",
		},
		{
			"element address is not the header",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tmutate(&s[0])\n\treturn s\n}",
			{6},
			{6},
			"slice",
		},
		{
			"repointed slice does not clear the array",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\treplace(&s)\n\treturn buf[:]\n}",
			{6},
			{6},
			"slice",
		},
		{
			"branch may repoint the slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tif cond {\n\t\treplace(&s)\n\t}\n\treturn s\n}",
			{8},
			{},
			"",
		},
		{
			"condition may repoint the slice",
			"package a\nf :: proc() -> []u8 {\n\tbuf: [4]u8\n\ts := buf[:]\n\tif replace(&s) {\n\t\treturn s\n\t}\n\treturn nil\n}",
			{6},
			{},
			"",
		},
	}
	for c in cases {
		got := collect(temp_scope(c.src, ..c.lines), check_borrowed_escape, context.temp_allocator)
		testing.expectf(t, len(got) == len(c.want), "%s: got %v, want %v", c.name, got, c.want)
		for f, i in got {
			testing.expect_value(t, f.rule, "odin-borrowed-escape")
			testing.expect_value(t, f.severity, finding.Severity.Must_Fix)
			if i < len(c.want) {
				testing.expectf(t, f.line == c.want[i], "%s: line %d, want %d", c.name, f.line, c.want[i])
			}
		}
		if c.text != "" && len(got) > 0 {
			testing.expectf(
				t,
				strings.contains(got[0].message, c.text),
				"%s: message %q",
				c.name,
				got[0].message,
			)
			if c.text != "temporary" {
				testing.expectf(
					t,
					strings.contains(got[0].message, "buf"),
					"%s: message %q",
					c.name,
					got[0].message,
				)
			}
		}
	}
}
