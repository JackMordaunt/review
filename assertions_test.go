package main

import "testing"

func TestAssertless(t *testing.T) {
	for _, test := range []struct {
		fn    Function
		fires bool
	}{
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tParse(\"a\")\n}"}, true},
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tif Parse(\"a\") == nil {\n\t\tt.Fatal(\"nil\")\n\t}\n}"}, false},
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(tc *testing.T) {\n\ttc.Errorf(\"x\")\n}"}, false},
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tcheck(t, Parse(\"a\"))\n}"}, false},
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tt.Run(\"sub\", func(t *testing.T) {})\n}"}, false},
		{Function{Name: "TestX", File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tt.Skip(\"never\")\n}"}, false},
		{Function{Name: "BenchmarkX", File: "x_test.go", Body: "func BenchmarkX(b *testing.B) {\n\tParse(\"a\")\n}"}, false},
		{Function{Name: "parses", File: "x.test.ts", Body: "test('parses', () => {\n  parse('a');\n});"}, true},
		{Function{Name: "parses", File: "x.test.ts", Body: "test('parses', () => {\n  expect(parse('a')).toBe(1);\n});"}, false},
		{Function{Name: "test_parse", File: "x.odin", Body: "test_parse :: proc(t: ^testing.T) {\n\tparse(\"a\")\n}"}, true},
		{Function{Name: "test_parse", File: "x.odin", Body: "test_parse :: proc(t: ^testing.T) {\n\ttesting.expect(t, parse(\"a\") == 1)\n}"}, false},
		{Function{Name: "test_parse", File: "x.py", Body: "def test_parse():\n    parse('a')\n"}, true},
		{Function{Name: "test_parse", File: "x.py", Body: "def test_parse():\n    assert parse('a') == 1\n"}, false},
		{Function{Name: "smoke", File: "x.rs", Body: "fn smoke() { parse(\"a\"); }"}, true},
		{Function{Name: "smoke", File: "x.rs", Body: "fn smoke() { assert_eq!(parse(\"a\"), 1); }"}, false},
		{Function{Name: "test_parse", File: "x.lua", Body: "function test_parse() parse('a') end"}, false},
	} {
		if got := assertless(test.fn); got != test.fires {
			t.Errorf("%s in %s: assertless %v, want %v\n%s", test.fn.Name, test.fn.File, got, test.fires, test.fn.Body)
		}
	}
}

func TestCheckTestAssertions(t *testing.T) {
	c := &Change{Tests: []Function{
		{Name: "TestA", File: "x_test.go", Line: 3, Body: "func TestA(t *testing.T) {\n\tParse(\"a\")\n}"},
		{Name: "TestB", File: "x_test.go", Line: 9, Body: "func TestB(t *testing.T) {\n\tt.Fatal()\n}"},
	}}
	got := checkTestAssertions(c)
	if len(got) != 1 || got[0].Rule != "test-no-assertion" || got[0].Symbol != "TestA" || got[0].Severity != Consider {
		t.Errorf("got %v", got)
	}
}

func TestSkipLine(t *testing.T) {
	fn := Function{Line: 10, File: "x_test.go", Body: "func TestX(t *testing.T) {\n\tif !have {\n\t\tt.Skip(\"no tool\")\n\t}\n}"}
	if got := skipLine(fn); got != 12 {
		t.Errorf("got %d, want 12", got)
	}
	if got := skipLine(Function{Line: 1, Body: "func TestX(t *testing.T) {}"}); got != 0 {
		t.Errorf("got %d, want 0", got)
	}
}

func TestTautological(t *testing.T) {
	for _, line := range []string{
		`assert.True(t, true)`,
		`require.NoError(t, nil)`,
		`if got != got {`,
		`assert.Equal(t, want, want)`,
		`assert True`,
		`assert 1 == 1`,
		`self.assertTrue(True)`,
		`expect(true).toBe(true)`,
		`expect(1).toEqual(1)`,
		`expect(x.name).toBe(x.name)`,
		`assert!(true);`,
		`assert_eq!(2, 2);`,
		`assert_eq!(a.len(), a.len());`,
		`testing.expect(t, true)`,
	} {
		if tautological(line) == "" {
			t.Errorf("%q was not read as tautological", line)
		}
	}
	for _, line := range []string{
		`assert.True(t, ok)`,
		`require.NoError(t, err)`,
		`if got != want {`,
		`assert got == 1`,
		`expect(got).toBe(true)`,
		`expect(1).toEqual(got)`,
		`assert_eq!(a.len(), 2);`,
		`// assert.True(t, true) is what not to write`,
		`testing.expect(t, ok)`,
	} {
		if why := tautological(line); why != "" {
			t.Errorf("%q was read as %s", line, why)
		}
	}
}

func TestCheckTautologies(t *testing.T) {
	c := &Change{Tests: []Function{{Name: "TestX", File: "x_test.go", Line: 10, Body: "func TestX(t *testing.T) {\n\tgot := f()\n\tif got != got {\n\t\tt.Fatal()\n\t}\n}"}}}
	got := checkTautologies(c)
	if len(got) != 1 || got[0].Rule != "assertion-always-true" || got[0].Line != 12 || got[0].Severity != MustFix {
		t.Errorf("got %v", got)
	}
}
