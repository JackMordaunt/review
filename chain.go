package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

// probeTimeout bounds one reachability ask. A provider that cannot answer a
// trivial ask that quickly is unlikely to answer a job in time either, and
// the jobs are the expensive part.
const probeTimeout = 45 * time.Second

// Chain is a priority order of providers. The first one that answers a probe
// serves the whole reading, so a provider over its limit costs one cheap ask
// rather than a failed review. Which provider is reachable is a property of
// the hour: a team limit exhausted, a gateway asleep, a key unset — the chain
// is how the tool rides that out without being told.
type Chain []entry

type entry struct {
	Name     string
	Provider Provider
}

// defaultChain is the configured preference. The direct API is tried before
// the coding assistant, because it can enforce the answer's shape and reports
// usage; the local gateway is last, as the reading of last resort. The model
// flag re-points the first slot for a one-off, as it always has.
func defaultChain() Chain {
	return Chain{
		{"api/" + orElse(os.Getenv("REVIEW_MODEL"), "claude-sonnet-5"), API{Model: orElse(os.Getenv("REVIEW_MODEL"), "claude-sonnet-5")}},
		{"pi/maple/glm-5-3-flash", Pi{Model: "glm-5-3-flash", Upstream: "maple"}},
	}
}

// pick asks every entry a trivial question, in order, and returns the first
// that answers. Every failure is told to stderr, so a review run on the
// second choice says why the first was passed over. A reason is one line:
// a credential error walks the whole SDK ladder before it reaches the user,
// and the ladder is not what they asked about.
func (c Chain) pick(ctx context.Context, warn func(string)) (Provider, string, error) {
	first := func(err error) string {
		s := err.Error()
		if i := strings.IndexAny(s, "\r\n"); i >= 0 {
			s = s[:i]
		}
		return s
	}
	var reasons []string
	for _, e := range c {
		pctx, cancel := context.WithTimeout(ctx, probeTimeout)
		answer, err := e.Provider.Ask(pctx, "Answer the user's message.", "Answer with the single word OK.")
		cancel()
		if err == nil && strings.TrimSpace(answer.Text) != "" {
			return e.Provider, e.Name, nil
		}
		if err == nil {
			err = fmt.Errorf("answered nothing")
		}
		warn(fmt.Sprintf("skipping %s: %s", e.Name, first(err)))
		reasons = append(reasons, fmt.Sprintf("%s: %s", e.Name, first(err)))
	}
	return nil, "", fmt.Errorf("no provider answered: %s", strings.Join(reasons, "; "))
}
