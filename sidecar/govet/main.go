// review-vet is the analysis tool review hands to go vet with -vettool: the
// analysers vet runs by default, and the ones from golang.org/x/tools it
// leaves out — nilness, shadow, unusedwrite, the checks on sort, reflect and
// atomic misuse, and the modernize suite. Build it and put it on the path:
//
//	go build -o ~/go/bin/review-vet ./sidecar/govet
//
// Without it, review runs vet's default set.
package main

import (
	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/multichecker"
	"golang.org/x/tools/go/analysis/passes/appends"
	"golang.org/x/tools/go/analysis/passes/asmdecl"
	"golang.org/x/tools/go/analysis/passes/assign"
	"golang.org/x/tools/go/analysis/passes/atomic"
	"golang.org/x/tools/go/analysis/passes/atomicalign"
	"golang.org/x/tools/go/analysis/passes/bools"
	"golang.org/x/tools/go/analysis/passes/buildtag"
	"golang.org/x/tools/go/analysis/passes/cgocall"
	"golang.org/x/tools/go/analysis/passes/composite"
	"golang.org/x/tools/go/analysis/passes/copylock"
	"golang.org/x/tools/go/analysis/passes/deepequalerrors"
	"golang.org/x/tools/go/analysis/passes/defers"
	"golang.org/x/tools/go/analysis/passes/directive"
	"golang.org/x/tools/go/analysis/passes/errorsas"
	"golang.org/x/tools/go/analysis/passes/framepointer"
	"golang.org/x/tools/go/analysis/passes/hostport"
	"golang.org/x/tools/go/analysis/passes/httpmux"
	"golang.org/x/tools/go/analysis/passes/httpresponse"
	"golang.org/x/tools/go/analysis/passes/ifaceassert"
	"golang.org/x/tools/go/analysis/passes/loopclosure"
	"golang.org/x/tools/go/analysis/passes/lostcancel"
	"golang.org/x/tools/go/analysis/passes/modernize"
	"golang.org/x/tools/go/analysis/passes/nilfunc"
	"golang.org/x/tools/go/analysis/passes/nilness"
	"golang.org/x/tools/go/analysis/passes/printf"
	"golang.org/x/tools/go/analysis/passes/reflectvaluecompare"
	"golang.org/x/tools/go/analysis/passes/scannererr"
	"golang.org/x/tools/go/analysis/passes/shadow"
	"golang.org/x/tools/go/analysis/passes/shift"
	"golang.org/x/tools/go/analysis/passes/sigchanyzer"
	"golang.org/x/tools/go/analysis/passes/slog"
	"golang.org/x/tools/go/analysis/passes/sortslice"
	"golang.org/x/tools/go/analysis/passes/sqlrowserr"
	"golang.org/x/tools/go/analysis/passes/stdmethods"
	"golang.org/x/tools/go/analysis/passes/stdversion"
	"golang.org/x/tools/go/analysis/passes/stringintconv"
	"golang.org/x/tools/go/analysis/passes/structtag"
	"golang.org/x/tools/go/analysis/passes/testinggoroutine"
	"golang.org/x/tools/go/analysis/passes/tests"
	"golang.org/x/tools/go/analysis/passes/timeformat"
	"golang.org/x/tools/go/analysis/passes/unmarshal"
	"golang.org/x/tools/go/analysis/passes/unreachable"
	"golang.org/x/tools/go/analysis/passes/unsafeptr"
	"golang.org/x/tools/go/analysis/passes/unusedresult"
	"golang.org/x/tools/go/analysis/passes/unusedwrite"
	"golang.org/x/tools/go/analysis/passes/waitgroup"
)

func main() {
	// Vet's own set first, as vet runs it.
	analyzers := []*analysis.Analyzer{
		appends.Analyzer, asmdecl.Analyzer, assign.Analyzer, atomic.Analyzer, bools.Analyzer,
		buildtag.Analyzer, cgocall.Analyzer, composite.Analyzer, copylock.Analyzer, defers.Analyzer,
		directive.Analyzer, errorsas.Analyzer, framepointer.Analyzer, hostport.Analyzer,
		httpresponse.Analyzer, ifaceassert.Analyzer, loopclosure.Analyzer, lostcancel.Analyzer,
		nilfunc.Analyzer, printf.Analyzer, shift.Analyzer, sigchanyzer.Analyzer, slog.Analyzer,
		stdmethods.Analyzer, stdversion.Analyzer, stringintconv.Analyzer, structtag.Analyzer,
		testinggoroutine.Analyzer, tests.Analyzer, timeformat.Analyzer, unmarshal.Analyzer,
		unreachable.Analyzer, unsafeptr.Analyzer, unusedresult.Analyzer, waitgroup.Analyzer,
	}
	// The ones vet leaves out. nilness needs SSA and finds nil dereferences
	// and impossible comparisons; the sort, reflect, sql and bufio checks
	// find misuse the type checker allows; shadow and unusedwrite are
	// judgement calls, reported as such.
	analyzers = append(analyzers,
		nilness.Analyzer, atomicalign.Analyzer, deepequalerrors.Analyzer, httpmux.Analyzer,
		reflectvaluecompare.Analyzer, scannererr.Analyzer, sortslice.Analyzer, sqlrowserr.Analyzer,
		shadow.Analyzer, unusedwrite.Analyzer,
	)
	// modernize reports an older idiom where a newer one exists: taste, and
	// review reports it as a note.
	analyzers = append(analyzers, modernize.Suite...)
	multichecker.Main(analyzers...)
}
