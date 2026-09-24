package check

// Three of the naming rules need no judgement. Whether a name repeats its
// package, shadows something the language already names, or carries an
// invented abbreviation is a comparison against a list.

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../change"
import "../finding"
import "../txt"

@(private = "file")
predeclared: map[string]bool
@(private = "file")
stdlib: map[string]bool
@(private = "file")
globals: map[string]bool
@(private = "file")
builtins: map[string]bool
@(private = "file")
shell_builtins: map[string]bool
@(private = "file")
shell_utilities: map[string]bool
@(private = "file")
abbreviations: map[string]bool

@(init)
init_name_lists :: proc "contextless" () {
	context = runtime.default_context()
	// Go's universe-block identifiers. A package-level name that takes
	// one compiles, and then the builtin is gone for the whole package.
	predeclared = set(
		`append bool byte cap clear close complex complex64 complex128 copy delete error false
		float32 float64 imag int int8 int16 int32 int64 iota len make max min new nil panic print println
		real recover rune string true uint uint8 uint16 uint32 uint64 uintptr any comparable`,
	)
	// The standard library packages a Go file is likeliest to import.
	stdlib = set(
		`bufio bytes cmp context errors fmt io log maps math os path reflect regexp slices sort
		strconv strings sync testing time unicode url http json exec filepath rand hash flag template`,
	)
	// The names a browser or Node runtime already binds.
	globals = set(
		`Promise Map Set Array Object Error JSON Math Date Symbol String Number Boolean console
		window document process require module exports fetch event location history navigator`,
	)
	// Python's builtins, the ones a module-level name is likeliest to take
	// by accident.
	builtins = set(
		`abs all any bin bool bytes callable chr dict dir divmod enumerate eval exec filter
		float format frozenset getattr hasattr hash help hex id input int isinstance issubclass iter len list
		locals map max min next object oct open ord pow print property range repr reversed round set setattr
		slice sorted str sum super tuple type vars zip`,
	)
	// The shell's own builtins. A function that takes one of these names
	// is what the rest of the script reaches instead.
	shell_builtins = set(
		`alias bg break cd command continue declare echo eval exec exit export false fg getopts
		hash jobs kill local printf pwd read readonly return set shift source test times trap true type
		typeset ulimit umask unalias unset wait`,
	)
	// The utilities a script reaches for as though they were the
	// language. A function taking one of these names is a wrapper until
	// the day somebody expects the utility.
	shell_utilities = set(
		`awk basename cat chmod cp curl cut date diff dirname find grep head install ln ls mkdir
		mktemp mv rm sed sort tail tar tee touch tr uniq wc xargs`,
	)
	// The shortenings the discipline rejects. Established ones — id, url,
	// ctx, msg, err, buf, cmd, tmp — are words in their own right.
	abbreviations = set(
		`cfg mgr mgmt hdlr hndlr hndl svc ctrl ctlr btn cnt amt qty calc tbl usr pwd dflt nbr mdl
		srvr clnt rslt chk upd`,
	)
}

// check_names reports the naming faults a comparison can settle: stutter
// against the package, shadowing of a predeclared or well-known name,
// and abbreviations the discipline rejects.
check_names :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	for sym in s.c.symbols {
		if is_test_file(sym.file) {
			continue
		}
		stutter(sym, out)
		shadow(sym, change.shell_for(s.c, sym.file), out)
		abbreviated(sym, out)
	}
}

// stutter reports a name whose first word is its package. The package's
// name is already said wherever the name is used, so the word is said
// twice: ico.IcoEntry. A type named exactly for its package is the
// language's own idiom — time.Time — and is spared, as is anything in
// package main, which nothing qualifies.
stutter :: proc(sym: change.Symbol, out: ^[dynamic]finding.Finding) {
	if sym.pkg == "" || sym.pkg == "main" || !sym.exported {
		return
	}
	words := txt.split_words(sym.name, context.temp_allocator)
	if len(words) < 2 {
		return
	}
	pkg, _ := strings.replace_all(sym.pkg, "_", "", context.temp_allocator)
	if strings.to_lower(words[0], context.temp_allocator) !=
	   strings.to_lower(pkg, context.temp_allocator) {
		return
	}
	append(
		out,
		static(
			"no-stutter",
			.Consider,
			fmt.aprintf(
				"%s repeats its package: %s.%s says %s twice",
				sym.name,
				sym.pkg,
				sym.name,
				words[0],
			),
			fmt.aprintf(
				"drop the package's word: %s.%s",
				sym.pkg,
				strings.join(words[1:], "", context.temp_allocator),
			),
			file = sym.file,
			line = sym.line,
			symbol = sym.name,
		),
	)
}

// shadow reports a name the language or its runtime already means
// something by: Go's predeclared identifiers and standard library
// packages, the runtime's globals for TypeScript and JavaScript, the
// builtins for Python, and the builtins and standard utilities for a
// shell script.
shadow :: proc(sym: change.Symbol, shell: string, out: ^[dynamic]finding.Finding) {
	what, why: string
	switch {
	case shell != "":
		switch {
		case shell_builtins[sym.name]:
			what, why = "a shell builtin", "the builtin is gone for the rest of the script"
		case shell_utilities[sym.name]:
			what, why =
				"a standard utility",
				"every later call means this function, whoever wrote the line"
		}
	case strings.has_suffix(sym.file, ".go"):
		switch {
		case predeclared[sym.name]:
			what, why = "a predeclared identifier", "the builtin is gone for the whole package"
		case stdlib[sym.name]:
			what, why =
				"a standard library package",
				"no file in the package can import it beside this name"
		}
	case grammar_of(sym.file) != "":
		if globals[sym.name] {
			what, why =
				"a runtime global", "the runtime's is shadowed for every reader of the module"
		}
	case strings.has_suffix(sym.file, ".py"):
		if builtins[sym.name] {
			what, why = "a builtin", "the builtin is gone for the whole module"
		}
	}
	if what == "" {
		return
	}
	append(
		out,
		static(
			"no-shadow",
			.Consider,
			fmt.aprintf("%s is %s, and %s", sym.name, what, why),
			"name it for what it is here, in a word the language does not already use",
			file = sym.file,
			line = sym.line,
			symbol = sym.name,
		),
	)
}

// abbreviated reports a name carrying an invented abbreviation: a word
// the reader has to expand rather than read.
abbreviated :: proc(sym: change.Symbol, out: ^[dynamic]finding.Finding) {
	hit := make([dynamic]string, context.temp_allocator)
	for word in txt.split_words(sym.name, context.temp_allocator) {
		if abbreviations[strings.to_lower(word, context.temp_allocator)] {
			append(&hit, word)
		}
	}
	if len(hit) == 0 {
		return
	}
	append(
		out,
		static(
			"abbreviation",
			.Consider,
			fmt.aprintf(
				"%s abbreviates %s; an invented abbreviation is a word the reader expands rather than reads",
				sym.name,
				strings.join(hit[:], ", ", context.temp_allocator),
			),
			"write the word out",
			file = sym.file,
			line = sym.line,
			symbol = sym.name,
		),
	)
}
