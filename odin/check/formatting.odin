package check

// A commit that reformats and changes logic in one diff hides the logic
// among the reformatting, and neither can be reverted alone. Git can count
// which changed lines change only whitespace, and the count is the check.

import "core:fmt"

import "../finding"

// formatting_share is the share of a change's lines that change only
// whitespace at which the change is a reformatting with logic mixed in;
// formatting_floor the fewest whitespace-only lines worth a word;
// logic_floor the fewest lines that change something else.
formatting_share :: 0.5
formatting_floor :: 20
logic_floor      :: 10

// check_formatting reports a change whose diff is mostly whitespace and
// yet carries logic too: two changes that should be two commits.
check_formatting :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	c := s.c
	if c.changed == 0 || c.whitespace < formatting_floor {
		return
	}
	logic := c.changed - c.whitespace
	if logic < logic_floor {
		return
	}
	if f64(c.whitespace) / f64(c.changed) < formatting_share {
		return
	}
	append(
		out,
		static(
			"formatting-mixed-in",
			.Consider,
			fmt.aprintf(
				"%d of the change's %d lines change only whitespace, and %d change something else; a reformatting with logic in it hides the logic, and neither half can be reverted alone",
				c.whitespace,
				c.changed,
				logic,
			),
			"commit the reformatting on its own, then the change",
		),
	)
}
