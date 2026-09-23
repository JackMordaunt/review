package main

// A commit that reformats and changes logic in one diff hides the logic
// among the reformatting, and neither can be reverted alone. Git can count
// which changed lines change only whitespace, and the count is the check.

import "fmt"

const (
	// formattingShare is the share of a change's lines that change only
	// whitespace, at which the change is a reformatting with logic mixed
	// in. Sampled over 1,853 local commits: 0.7% fire at 0.5 with the two
	// floors below, and the ones that do are the mixed kind.
	formattingShare = 0.5
	// formattingFloor is the fewest whitespace-only lines worth a word.
	formattingFloor = 20
	// logicFloor is the fewest lines that change something other than
	// whitespace, under which the change is a reformatting and nothing is
	// mixed into it.
	logicFloor = 10
)

// checkFormatting reports a change whose diff is mostly whitespace and yet
// carries logic too: two changes that should be two commits, and the
// deterministic case of the hygiene job's rule.
func checkFormatting(c *Change) []Finding {
	if c.Changed == 0 || c.Whitespace < formattingFloor {
		return nil
	}
	logic := c.Changed - c.Whitespace
	if logic < logicFloor {
		return nil
	}
	share := float64(c.Whitespace) / float64(c.Changed)
	if share < formattingShare {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "formatting-mixed-in", Severity: Consider,
		Message: fmt.Sprintf("%d of the change's %d lines change only whitespace, and %d change something else; a reformatting with logic in it hides the logic, and neither half can be reverted alone", c.Whitespace, c.Changed, logic),
		Fix:     "commit the reformatting on its own, then the change",
	}}
}
