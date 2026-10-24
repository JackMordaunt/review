package reviewer

import "core:strings"
import "core:testing"

import "../change"
import "../job"
import "../provider"

// echoing is a provider that answers every ask with the text given.
echoing :: proc(text: string) -> provider.Provider {
	argv := make([]string, 2, context.temp_allocator)
	argv[0], argv[1] = "echo", text
	return provider.Provider{kind = .Command, argv = argv}
}

with_tests :: proc() -> change.Change {
	c := change.Change{}
	c.tests = make([dynamic]change.Function, context.temp_allocator)
	append(
		&c.tests,
		change.Function {
			name = "TestX",
			file = "x_test.go",
			line = 4,
			body = "func TestX(t *testing.T) {}",
		},
	)
	return c
}

@(test)
findings_are_read_and_jobs_without_a_subject_are_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := echoing(
		`{"findings":[{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"symbol":"TestX","message":"asserts nothing","fix":"assert"},{"rule":"invented","severity":"note","message":"x","fix":"y"}]}`,
	)
	r := Reviewer {
		provider = p,
		name     = provider.name(p),
		verify   = false,
	}
	c := with_tests()
	result := run(&r, &c, job.all(), serial = true)
	testing.expect_value(t, len(result.failures), 0)
	testing.expect_value(t, len(result.findings), 1)
	if len(result.findings) == 1 {
		f := result.findings[0]
		testing.expect_value(t, f.job, "tests")
		testing.expect_value(t, f.rule, "cannot-fail")
		testing.expect_value(t, f.line, 4)
		testing.expect(t, !f.verified)
	}
	testing.expect_value(
		t,
		strings.join(result.skipped[:], ",", context.temp_allocator),
		"duplication,namer,claims,hygiene,odin,stanzas",
	)
}

@(test)
a_second_reading_retracts_what_it_does_not_hold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// One answer that is both a findings object and a verdicts object:
	// the first reading reports one finding, the second says it falls.
	p := echoing(
		`{"findings":[{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"symbol":"TestX","message":"m","fix":"f"}],"verdicts":[{"index":0,"holds":false,"reason":"the test can fail"}]}`,
	)
	r := Reviewer {
		provider = p,
		name     = provider.name(p),
		verify   = true,
	}
	c := with_tests()
	result := run(&r, &c, job.all(), serial = true)
	testing.expect_value(t, len(result.failures), 0)
	testing.expect_value(t, len(result.findings), 0)
	testing.expect_value(t, len(result.retracted), 1)
	if len(result.retracted) == 1 {
		testing.expect_value(t, result.retracted[0].reason, "the test can fail")
		testing.expect_value(t, result.retracted[0].finding.rule, "cannot-fail")
	}
	// A verdict that holds leaves the finding standing, verified.
	holds := echoing(
		`{"findings":[{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"symbol":"TestX","message":"m","fix":"f"}],"verdicts":[{"index":0,"holds":true,"reason":"it stands"}]}`,
	)
	r = Reviewer {
		provider = holds,
		name     = provider.name(holds),
		verify   = true,
	}
	c = with_tests()
	result = run(&r, &c, job.all(), serial = true)
	testing.expect_value(t, len(result.findings), 1)
	if len(result.findings) == 1 {
		testing.expect(t, result.findings[0].verified)
	}
}

@(test)
a_verdict_that_cannot_be_asked_fails_open :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The answer is findings only, so the verdict ask reads no verdicts
	// twice over: the findings stand unverified and the failure is named.
	p := echoing(
		`{"findings":[{"rule":"cannot-fail","severity":"must-fix","file":"x_test.go","line":4,"symbol":"TestX","message":"m","fix":"f"}]}`,
	)
	r := Reviewer {
		provider = p,
		name     = provider.name(p),
		verify   = true,
	}
	c := with_tests()
	result := run(&r, &c, job.all(), serial = true)
	testing.expect_value(t, len(result.findings), 1)
	if len(result.findings) == 1 {
		testing.expect(t, result.findings[0].verified)
	}
	testing.expectf(
		t,
		len(result.failures) == 0,
		"an omitted verdict stands rather than falls: %v",
		result.failures,
	)
	prose := echoing("I have nothing to say")
	r = Reviewer {
		provider = prose,
		name     = provider.name(prose),
		verify   = false,
	}
	c = with_tests()
	result = run(&r, &c, job.all(), serial = true)
	testing.expect_value(t, len(result.failures), 1)
	if len(result.failures) == 1 {
		testing.expect(
			t,
			strings.has_prefix(
				result.failures[0],
				"tests: no findings object in the answer, twice",
			),
		)
	}
}
