package main

import "testing"

func rulesOf(findings []Finding) []string {
	var out []string
	for _, f := range findings {
		out = append(out, f.Rule)
	}
	return out
}

func TestStutter(t *testing.T) {
	for _, test := range []struct {
		symbol Symbol
		fires  bool
	}{
		{Symbol{Name: "IcoEntry", Package: "ico", Exported: true, File: "ico/ico.go"}, true},
		{Symbol{Name: "exe_kind", Package: "exe", Exported: true, File: "exe/exe.odin"}, true},
		{Symbol{Name: "Time", Package: "time", Exported: true, File: "time/time.go"}, false},
		{Symbol{Name: "Entry", Package: "ico", Exported: true, File: "ico/ico.go"}, false},
		{Symbol{Name: "icoEntry", Package: "ico", Exported: false, File: "ico/ico.go"}, false},
		{Symbol{Name: "MainLoop", Package: "main", Exported: true, File: "main.go"}, false},
		{Symbol{Name: "Iconic", Package: "ico", Exported: true, File: "ico/ico.go"}, false},
	} {
		got := stutter(test.symbol)
		if (len(got) == 1) != test.fires {
			t.Errorf("%s in package %s: got %v", test.symbol.Name, test.symbol.Package, got)
		}
	}
}

func TestShadow(t *testing.T) {
	for _, test := range []struct {
		symbol Symbol
		fires  bool
	}{
		{Symbol{Name: "len", File: "x.go"}, true},
		{Symbol{Name: "url", File: "x.go"}, true},
		{Symbol{Name: "Promise", File: "x.ts"}, true},
		{Symbol{Name: "render", File: "x.go"}, false},
		{Symbol{Name: "len", File: "x.ts"}, false},
		{Symbol{Name: "Promise", File: "x.go"}, false},
	} {
		got := shadow(test.symbol, nil)
		if (len(got) == 1) != test.fires {
			t.Errorf("%s in %s: got %v", test.symbol.Name, test.symbol.File, got)
		}
	}
}

func TestAbbreviated(t *testing.T) {
	for _, test := range []struct {
		name  string
		fires bool
	}{
		{"loadCfg", true}, {"user_mgr", true}, {"BtnLabel", true},
		{"msgCount", false}, {"parseURL", false}, {"ctx", false}, {"configure", false},
	} {
		got := abbreviated(Symbol{Name: test.name, File: "x.go"})
		if (len(got) == 1) != test.fires {
			t.Errorf("%s: got %v", test.name, got)
		}
	}
}

// The check runs over the change's symbols and leaves test files alone.
func TestCheckNames(t *testing.T) {
	c := &Change{Symbols: []Symbol{
		{Name: "IcoEntry", Package: "ico", Exported: true, File: "ico/ico.go", Line: 3},
		{Name: "cfg", File: "ico/ico.go", Line: 9},
		{Name: "cfgForTests", File: "ico/ico_test.go", Line: 4},
	}, Imports: map[string][]string{}}
	got := rulesOf(checkNames(c))
	if len(got) != 2 || got[0] != "no-stutter" || got[1] != "abbreviation" {
		t.Errorf("got %v", got)
	}
}
