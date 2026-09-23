/*
Package report is the whole measurement a program reads: what was found,
what the second reading did not let stand, what was dismissed in the
source, and how complete the measurement was. The status is what makes an
empty findings list readable: "complete" is the only status an empty list
can be read as a pass against, because the others say which part of the
measurement is missing. The JSON is the Go tool's, key for key.
*/
package report

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "../change"
import "../finding"

version :: 1

// Job_Fault is one job that could not finish, and what failed about it.
Job_Fault :: struct {
	job:   string `json:"job"`,
	error: string `json:"error"`,
}

// Metered is what the asks cost, in tokens and dollars. Answers replayed
// from the cache count as replayed rather than as usage.
Metered :: struct {
	tokens_in:  int `json:"in"`,
	tokens_out: int `json:"out"`,
	cached:     int `json:"cached"`,
	replayed:   int `json:"replayed"`,
	cost:       f64 `json:"usd"`,
}

// Retracted is a finding the second reading did not let stand, and why.
Retracted :: struct {
	finding: finding.Finding `json:"finding"`,
	reason:  string `json:"reason"`,
}

// Dismissed is a finding the source itself answered, and the answer.
Dismissed :: struct {
	finding: finding.Finding `json:"finding"`,
	why:     string `json:"why"`,
}

// Baseline is this run's findings named against a previous report's, by
// id. A loop reads resolved to know its fixes took, persisting to know
// what is left, and new to know what the fixes cost.
Baseline :: struct {
	from:       string `json:"from"`,
	resolved:   []string `json:"resolved"`,
	persisting: []string `json:"persisting"`,
	new:        []string `json:"new"`,
}

Contract :: struct {
	version:   int `json:"version"`,
	status:    string `json:"status"`,
	provider:  string `json:"provider,omitempty"`,
	findings:  []finding.Finding `json:"findings"`,
	retracted: []Retracted `json:"retracted"`,
	failed:    []Job_Fault `json:"failed"`,
	skipped:   []string `json:"skipped"`,
	uncovered: []change.Gap `json:"uncovered"`,
	dismissed: []Dismissed `json:"dismissed"`,
	truncated: bool `json:"truncated,omitempty"`,
	baseline:  Maybe(Baseline) `json:"baseline,omitempty"`,
	usage:     Metered `json:"usage"`,
}

// status_of is how complete the measurement was: a job that failed, a
// file no reader covered, or a diff cut short each leave a hole.
status_of :: proc(c: change.Change, failures: int) -> string {
	if failures > 0 || len(c.uncovered) > 0 || c.truncated {
		return "incomplete"
	}
	return "complete"
}

// filter drops the findings the source itself dismisses, and keeps them
// so that a silent dismissal can still be read back.
filter :: proc(
	root: string,
	findings: []finding.Finding,
	allocator := context.allocator,
) -> (
	kept: []finding.Finding,
	dismissed: []Dismissed,
) {
	keep := make([dynamic]finding.Finding, allocator)
	drop := make([dynamic]Dismissed, allocator)
	for f in findings {
		if why, ok := finding.suppressed(f, root, allocator); ok {
			append(&drop, Dismissed{f, why})
			continue
		}
		append(&keep, f)
	}
	return keep[:], drop[:]
}

// render is the report as a person reads it, grouped by severity, the
// serious first. A dismissal reaches a few lines either side of itself,
// so which findings one answered is worth being able to read when asked;
// a retraction is the second reading's word against the first's.
render :: proc(env: Contract, verbose := false, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if verbose {
		for d in env.dismissed {
			fmt.sbprintf(
				&b,
				"  dismissed: %s:%d %s (%s)\n",
				d.finding.file,
				d.finding.line,
				d.finding.rule,
				d.why,
			)
		}
		for r in env.retracted {
			fmt.sbprintf(
				&b,
				"  retracted: [%s] %s:%d — %s\n",
				r.finding.rule,
				r.finding.file,
				r.finding.line,
				first(r.reason, 120),
			)
		}
	}
	if len(env.findings) == 0 {
		strings.write_string(&b, "no findings")
		if len(env.dismissed) > 0 {
			fmt.sbprintf(&b, " (%d dismissed in the source)", len(env.dismissed))
		}
		strings.write_string(&b, "\n")
		notes(&b, env)
		return strings.to_string(b)
	}
	announced := false
	severity: finding.Severity
	for f in env.findings {
		if !announced || f.severity != severity {
			severity = f.severity
			announced = true
			fmt.sbprintf(
				&b,
				"\n%s\n",
				strings.to_upper(finding.severity_name(severity), context.temp_allocator),
			)
		}
		line := finding.to_string(f, context.temp_allocator)
		indented, _ := strings.replace_all(line, "\n      ", "\n    ", context.temp_allocator)
		fmt.sbprintf(&b, "  %s\n", indented)
	}
	fmt.sbprintf(&b, "\n%d findings", len(env.findings))
	if len(env.dismissed) > 0 {
		fmt.sbprintf(&b, ", %d dismissed in the source", len(env.dismissed))
	}
	strings.write_string(&b, "\n")
	notes(&b, env)
	if verbose {
		strings.write_string(
			&b,
			"\nDismiss a finding where it is wrong, in the source it concerns:\n  //review:ignore <rule> <why>\n",
		)
	}
	return strings.to_string(b)
}

// notes says what a reader would otherwise miss: findings that did not
// survive verification, and how the run stands against a baseline.
notes :: proc(b: ^strings.Builder, env: Contract) {
	if len(env.retracted) > 0 {
		fmt.sbprintf(
			b,
			"%d of the findings reported did not survive verification\n",
			len(env.retracted),
		)
	}
	if base, given := env.baseline.?; given {
		fmt.sbprintf(
			b,
			"against %s: %d resolved, %d persisting, %d new\n",
			base.from,
			len(base.resolved),
			len(base.persisting),
			len(base.new),
		)
		if len(base.persisting) > 0 {
			fmt.sbprintf(
				b,
				"  persisting: %s\n",
				strings.join(base.persisting, ", ", context.temp_allocator),
			)
		}
	}
}

// encode is the contract as JSON. Every list is said even when empty: a
// key an agent cannot find is a hole it guesses about. Each finding is
// given its stable id and its severity as text, which is what a loop
// needs to answer a finding and check it stayed answered.
encode :: proc(env: Contract, allocator := context.allocator) -> (out: string, ok: bool) {
	named := env
	named.version = version
	named.findings = present(env.findings, context.temp_allocator)
	named.retracted = present(env.retracted, context.temp_allocator)
	named.failed = present(env.failed, context.temp_allocator)
	named.skipped = present(env.skipped, context.temp_allocator)
	named.uncovered = present(env.uncovered, context.temp_allocator)
	named.dismissed = present(env.dismissed, context.temp_allocator)
	finding.name(named.findings, context.temp_allocator)
	retracted := make([]finding.Finding, len(named.retracted), context.temp_allocator)
	for r, i in named.retracted {
		retracted[i] = r.finding
	}
	finding.name(retracted, context.temp_allocator)
	for &r, i in named.retracted {
		r.finding = retracted[i]
	}
	dismissed := make([]finding.Finding, len(named.dismissed), context.temp_allocator)
	for d, i in named.dismissed {
		dismissed[i] = d.finding
	}
	finding.name(dismissed, context.temp_allocator)
	for &d, i in named.dismissed {
		d.finding = dismissed[i]
	}
	data, err := json.marshal(
		named,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	if err != nil {
		return "", false
	}
	return compact(string(data), allocator), true
}

// compact writes an empty list as [] on one line, where the marshaller
// leaves a blank line inside it, and leaves out a truncation that did not
// happen, as the Go tool does.
compact :: proc(text: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(text, "\n  \"truncated\": false,", "", context.temp_allocator)
	for depth in 0 ..< 8 {
		indent := strings.repeat("  ", depth, context.temp_allocator)
		pattern := strings.concatenate({"[\n\n", indent, "]"}, context.temp_allocator)
		out, _ = strings.replace_all(out, pattern, "[]", context.temp_allocator)
	}
	return strings.clone(out, allocator)
}

// present is a slice that is never nil, so that it is written as [] rather
// than left out or written as null.
present :: proc(items: []$T, allocator := context.allocator) -> []T {
	if items == nil {
		return make([]T, 0, allocator)
	}
	copied := make([]T, len(items), allocator)
	copy(copied, items)
	return copied
}

// first is the start of a string, with an ellipsis where it was cut.
first :: proc(s: string, n: int, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(s)
	if len(trimmed) > n {
		return strings.concatenate({trimmed[:n], "…"}, allocator)
	}
	return trimmed
}
