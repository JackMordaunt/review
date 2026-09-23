package main

// Three of the naming rules need no judgement. Whether a name repeats its
// package, shadows something the language already names, or carries an
// invented abbreviation is a comparison against a list, and a list is
// measured here rather than read by a model.

import (
	"fmt"
	"strings"
)

// checkNames reports the naming faults a comparison can settle: stutter
// against the package, shadowing of a predeclared or well-known name, and
// abbreviations the discipline rejects.
func checkNames(c *Change) []Finding {
	var out []Finding
	for _, s := range c.Symbols {
		if isTestFile(s.File) {
			continue
		}
		out = append(out, stutter(s)...)
		out = append(out, shadow(s, c.Imports[s.File])...)
		out = append(out, abbreviated(s)...)
	}
	return out
}

// stutter reports a name whose first word is its package. The package's
// name is already said wherever the name is used, so the word is said
// twice: ico.IcoEntry, exe.ExeKind. A type named exactly for its package
// is the language's own idiom — time.Time, context.Context — and is spared,
// as is anything in package main, which nothing qualifies.
func stutter(s Symbol) []Finding {
	if s.Package == "" || s.Package == "main" || !s.Exported {
		return nil
	}
	words := split(s.Name)
	if len(words) < 2 {
		return nil
	}
	pkg := strings.ToLower(strings.ReplaceAll(s.Package, "_", ""))
	if strings.ToLower(words[0]) != pkg {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "no-stutter", Severity: Consider,
		File: s.File, Line: s.Line, Symbol: s.Name,
		Message: fmt.Sprintf("%s repeats its package: %s.%s says %s twice", s.Name, s.Package, s.Name, words[0]),
		Fix:     fmt.Sprintf("drop the package's word: %s.%s", s.Package, strings.Join(words[1:], "")),
	}}
}

// predeclared are Go's universe-block identifiers. A package-level name
// that takes one compiles, and then the builtin is gone for the whole
// package.
var predeclared = map[string]bool{
	"append": true, "bool": true, "byte": true, "cap": true, "clear": true, "close": true,
	"complex": true, "complex64": true, "complex128": true, "copy": true, "delete": true,
	"error": true, "false": true, "float32": true, "float64": true, "imag": true,
	"int": true, "int8": true, "int16": true, "int32": true, "int64": true, "iota": true,
	"len": true, "make": true, "max": true, "min": true, "new": true, "nil": true,
	"panic": true, "print": true, "println": true, "real": true, "recover": true,
	"rune": true, "string": true, "true": true, "uint": true, "uint8": true,
	"uint16": true, "uint32": true, "uint64": true, "uintptr": true, "any": true,
	"comparable": true,
}

// stdlib are the standard library packages a Go file is likeliest to
// import. A package-level name that takes one cannot share a file with the
// import, so the next file to need the package renames one or the other.
var stdlib = map[string]bool{
	"bufio": true, "bytes": true, "cmp": true, "context": true, "errors": true,
	"fmt": true, "io": true, "log": true, "maps": true, "math": true, "os": true,
	"path": true, "reflect": true, "regexp": true, "slices": true, "sort": true,
	"strconv": true, "strings": true, "sync": true, "testing": true, "time": true,
	"unicode": true, "url": true, "http": true, "json": true, "exec": true,
	"filepath": true, "rand": true, "hash": true, "flag": true, "template": true,
}

// globals are the names a browser or Node runtime already binds. A module
// that declares one at the top level shadows the runtime's for every
// reader of the module.
var globals = map[string]bool{
	"Promise": true, "Map": true, "Set": true, "Array": true, "Object": true,
	"Error": true, "JSON": true, "Math": true, "Date": true, "Symbol": true,
	"String": true, "Number": true, "Boolean": true, "console": true,
	"window": true, "document": true, "process": true, "require": true,
	"module": true, "exports": true, "fetch": true, "event": true,
	"location": true, "history": true, "navigator": true,
}

// builtins are Python's, the ones a module-level name is likeliest to take
// by accident: id, type, input, list.
var builtins = set(`abs all any bin bool bytes callable chr dict dir divmod enumerate eval exec filter
	float format frozenset getattr hasattr hash help hex id input int isinstance issubclass iter len list
	locals map max min next object oct open ord pow print property range repr reversed round set setattr
	slice sorted str sum super tuple type vars zip`)

// shadow reports a name the language or its runtime already means
// something by. Go's predeclared identifiers and the standard library's
// package names are measured for Go; the runtime's globals for TypeScript
// and JavaScript; the builtins for Python.
func shadow(s Symbol, imports []string) []Finding {
	var (
		what string
		why  string
	)
	switch {
	case strings.HasSuffix(s.File, ".go"):
		switch {
		case predeclared[s.Name]:
			what, why = "a predeclared identifier", "the builtin is gone for the whole package"
		case stdlib[s.Name]:
			what, why = "a standard library package", "no file in the package can import it beside this name"
		}
	case grammarOf(s.File) != "":
		if globals[s.Name] {
			what, why = "a runtime global", "the runtime's is shadowed for every reader of the module"
		}
	case strings.HasSuffix(s.File, ".py"):
		if builtins[s.Name] {
			what, why = "a builtin", "the builtin is gone for the whole module"
		}
	}
	if what == "" {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "no-shadow", Severity: Consider,
		File: s.File, Line: s.Line, Symbol: s.Name,
		Message: fmt.Sprintf("%s is %s, and %s", s.Name, what, why),
		Fix:     "name it for what it is here, in a word the language does not already use",
	}}
}

// abbreviations are the shortenings the discipline rejects. Established
// ones — id, url, ctx, msg, err, buf, cmd, tmp — are words in their own
// right and are not here.
var abbreviations = map[string]bool{
	"cfg": true, "mgr": true, "mgmt": true, "hdlr": true, "hndlr": true, "hndl": true,
	"svc": true, "ctrl": true, "ctlr": true, "btn": true, "cnt": true, "amt": true,
	"qty": true, "calc": true, "tbl": true, "usr": true, "pwd": true, "dflt": true,
	"nbr": true, "mdl": true, "srvr": true, "clnt": true, "rslt": true, "chk": true,
	"upd": true,
}

// abbreviated reports a name carrying an invented abbreviation: a word the
// reader has to expand rather than read.
func abbreviated(s Symbol) []Finding {
	var hit []string
	for _, word := range split(s.Name) {
		if abbreviations[strings.ToLower(word)] {
			hit = append(hit, word)
		}
	}
	if len(hit) == 0 {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "abbreviation", Severity: Consider,
		File: s.File, Line: s.Line, Symbol: s.Name,
		Message: fmt.Sprintf("%s abbreviates %s; an invented abbreviation is a word the reader expands rather than reads", s.Name, strings.Join(hit, ", ")),
		Fix:     "write the word out",
	}}
}
