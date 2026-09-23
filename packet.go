package main

import (
	"cmp"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// Change is everything the jobs are allowed to see, gathered once. Each job
// takes the part it needs and no more: a job that reads less is both cheaper
// and harder to distract.
type Change struct {
	// Diff is the change itself, capped.
	Diff string
	// Files are the paths it touches.
	Files []string
	// Message is the commit message under review. Empty for a staged change
	// unless the caller supplied one, and then nothing measures it.
	Message string
	// Stat is the per-file line counts, which is enough to notice a commit
	// doing two things without reading either.
	Stat string
	// Truncated is whether the diff was capped, which makes every count
	// under it a count of what was read rather than of what changed.
	Truncated bool
	// Uncovered is the part of the change the deterministic side could not
	// read, with a reason for each file. Jobs read what they can; what
	// they could not is said rather than missed.
	Uncovered []Gap
	// Symbols are the declarations the change adds or renames.
	Symbols []Symbol
	// Tests are the test functions it adds or changes, whole.
	Tests []Function
	// Comments are the comment and documentation lines it adds.
	Comments []Located
	// Candidates are existing names that resemble each new one, gathered by
	// search rather than by the model, which is what keeps the duplication
	// job cheap.
	Candidates map[string][]string
	// Twins are the existing declarations holding the same literal as a new
	// one. They are the shortest list worth reading, so they are kept apart
	// from the resemblances they would otherwise be buried in.
	Twins map[string][]string
	// Convention is the recent commit subjects, so a job can read the local
	// habit rather than impose one.
	Convention []string
	// History is the subjects of the repository's last thousand commits, the
	// word frequencies the commit message is measured against.
	History []string
	// Temporal is what the repository's history counts about the files the
	// change touches: how many commits touch each, and which other files
	// those commits also touched. Nil when the history says nothing.
	Temporal *Temporal
	// Imports names, per file, the packages the file imports, for the
	// languages whose frontend reads them. A new name that shadows one is
	// measured against this.
	Imports map[string][]string
	// Changed is how many lines the diff adds and removes, counted by git
	// over the whole change rather than the capped diff; Whitespace is how
	// many of them change nothing but whitespace. The formatting check
	// reads both.
	Changed, Whitespace int

	// index is every declaration in the repository at the end of the
	// change, kept for the readings that judge new work against it.
	index []Declared
	// root and rev locate the tree the change arrives at, for the checks
	// that read the repository rather than the diff.
	root, rev string
}

// Temporal is the counted history of the files a change touches.
type Temporal struct {
	// Commits counts, over the counted commits, how many touch each file.
	Commits map[string]int
	// Partners lists, per changed file, the other files those commits also
	// touched, nearest first.
	Partners map[string][]Partner
}

// Partner is another file that history shows changing with a changed one.
type Partner struct {
	Name   string
	Shared int
}

// Symbol is a declaration the change introduces.
type Symbol struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Doc      string `json:"doc,omitempty"`
	File     string `json:"file"`
	Line     int    `json:"line"`
	Exported bool   `json:"exported"`
	// Signature is the declaration line, which is what a name has to be
	// judged against.
	Signature string `json:"signature,omitempty"`
	// Body is the whole declaration where it has a body: a function's, for
	// the checks that measure one.
	Body string `json:"body,omitempty"`
	// Package is the package the file declares, where the language has
	// one; a name is measured against it for stutter.
	Package string `json:"package,omitempty"`
}

// Function is a whole function, which the test job needs because a test can
// only be judged by what it asserts.
type Function struct {
	Name string `json:"name"`
	File string `json:"file"`
	Line int    `json:"line"`
	Body string `json:"body"`
	// Skips is the line the test skips itself on, or zero. It is read from
	// the body by shape, so the reading that judges the skip is pointed at
	// it rather than left to find it.
	Skips int `json:"skips,omitempty"`
}

// Located is a line of prose and where it came from.
type Located struct {
	Text string `json:"text"`
	File string `json:"file"`
	Line int    `json:"line"`
	// Below is the code the comment sits above, a few lines of it, so
	// that a claim about behaviour can be read beside the behaviour.
	Below string `json:"below,omitempty"`
}

// Gap is a file the deterministic side could not read at all, and
// why. It is reported rather than skipped silently, because a job that
// read nothing reports nothing, and silence is what an empty findings list
// is made of.
type Gap struct {
	File   string `json:"file"`
	Reason string `json:"reason"`
}

// maxDiff caps what is sent. A change larger than this is reviewed by its
// parts rather than badly as a whole.
const maxDiff = 60000

// Gather collects the change at a revision range, or the staged change when
// the range is empty.
func Gather(rev string, root string) (*Change, error) {
	// The prefixes are named rather than inherited: diff.mnemonicPrefix
	// rewrites them per side, and the diff is parsed by them below.
	var diffArgs, nameArgs, statArgs []string
	switch rev {
	case "":
		diffArgs = []string{"diff", "--cached", "-U3", "--src-prefix=a/", "--dst-prefix=b/"}
		nameArgs = []string{"diff", "--cached", "--name-only"}
		statArgs = []string{"diff", "--cached", "--stat"}
	default:
		diffArgs = []string{"diff", rev, "-U3", "--src-prefix=a/", "--dst-prefix=b/"}
		nameArgs = []string{"diff", rev, "--name-only"}
		statArgs = []string{"diff", rev, "--stat"}
	}

	change := &Change{Candidates: map[string][]string{}, Twins: map[string][]string{}, Imports: map[string][]string{}, root: root, rev: rev}
	var err error
	if change.Diff, err = git(root, diffArgs...); err != nil {
		return nil, err
	}
	// The whitespace-only lines are what the diff loses when git is asked
	// to ignore whitespace; the difference is the formatting mixed in.
	if plain, err := git(root, append(numstat(rev), "--numstat")...); err == nil {
		if loose, err := git(root, append(numstat(rev), "-w", "--numstat")...); err == nil {
			change.Changed = countNumstat(plain)
			change.Whitespace = change.Changed - countNumstat(loose)
		}
	}
	if len(change.Diff) > maxDiff {
		change.Diff = change.Diff[:maxDiff] + "\n… diff truncated\n"
		change.Truncated = true
	}
	names, err := git(root, nameArgs...)
	if err != nil {
		return nil, err
	}
	for _, name := range strings.Split(strings.TrimSpace(names), "\n") {
		if name != "" {
			change.Files = append(change.Files, name)
		}
	}
	if change.Stat, err = git(root, statArgs...); err != nil {
		return nil, err
	}
	// A staged change has no message: git has none for a commit that does
	// not exist, and the previous commit's would be measured against work
	// it never described. The caller may supply one, as a commit-msg hook
	// does.
	if rev != "" {
		change.Message, _ = git(root, "log", "-1", "--format=%B", strings.TrimSuffix(rev, "^"))
	}
	if subjects, err := git(root, "log", "-12", "--format=%s"); err == nil {
		for _, s := range strings.Split(strings.TrimSpace(subjects), "\n") {
			if s != "" {
				change.Convention = append(change.Convention, s)
			}
		}
	}
	if subjects, err := git(root, "log", "-1000", "--format=%s"); err == nil {
		for _, s := range strings.Split(strings.TrimSpace(subjects), "\n") {
			if s != "" {
				change.History = append(change.History, s)
			}
		}
	}

	change.read(root, rev, frontends())
	change.findCandidates(root, rev, frontends())
	change.readTemporal(root, rev)
	change.annotate(root, rev)
	return change, nil
}

// numstat is the diff command for the change, without its format, so that
// the same change can be counted with and without whitespace.
func numstat(rev string) []string {
	if rev == "" {
		return []string{"diff", "--cached"}
	}
	return []string{"diff", rev}
}

// countNumstat sums the lines added and removed over git's --numstat
// output. A binary file's counts are dashes and count nothing.
func countNumstat(out string) int {
	n := 0
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		n += atoi(fields[0]) + atoi(fields[1])
	}
	return n
}

// annotate adds to what the frontends read the parts that every language
// shares: the code below each comment, and the line a test skips itself
// on. Both are read by shape from the source, once per file.
func (c *Change) annotate(root, rev string) {
	sources := map[string][]string{}
	lines := func(name string) []string {
		if l, ok := sources[name]; ok {
			return l
		}
		data, err := at(root, rev, name)
		if err != nil {
			sources[name] = nil
			return nil
		}
		sources[name] = strings.Split(string(data), "\n")
		return sources[name]
	}
	for i := range c.Comments {
		c.Comments[i].Below = codeBelow(lines(c.Comments[i].File), c.Comments[i].Line)
	}
	for i := range c.Tests {
		c.Tests[i].Skips = skipLine(c.Tests[i])
	}
}

// belowLines is how much code a comment is shown beside.
const belowLines = 2

// codeBelow is the code that follows a comment: the first lines after it
// that are neither blank nor comment, up to belowLines of them.
func codeBelow(lines []string, comment int) string {
	var out []string
	for i := comment; i < len(lines) && len(out) < belowLines; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if trimmed == "" || isCommentLine(trimmed) {
			if len(out) > 0 {
				break
			}
			continue
		}
		out = append(out, trimmed)
	}
	return strings.Join(out, "\n")
}

// isCommentLine is whether a trimmed line is a comment by the shapes the
// tool's languages share.
func isCommentLine(trimmed string) bool {
	return strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "/*") ||
		strings.HasPrefix(trimmed, "*") || (strings.HasPrefix(trimmed, "#") && !strings.HasPrefix(trimmed, "#!"))
}

// The counting window and width: the coupling is counted over the last
// thousand commits before the change, and a commit listing more than a
// hundred files is left out of the count — a sweep touching everything
// once says nothing about any pair, and leaving it out errs toward
// silence.
const (
	temporalWindow = 1000
	temporalWidth  = 100

	// partnerList is the fewest-nearest partners kept per changed file, so
	// a file whose history touches everything does not carry the history.
	partnerList = 20
)

// readTemporal counts, over the last thousand commits before the change,
// how often each changed file is touched by a commit that also touches
// another file. The history starts at the commit the change begins at, so
// the change under review is never counted against itself.
func (c *Change) readTemporal(root, rev string) {
	if len(c.Files) == 0 {
		return
	}
	var args []string
	start := ""
	switch {
	case rev == "":
	case strings.Contains(rev, ".."):
		start = strings.SplitN(rev, "..", 2)[0]
	case strings.HasSuffix(rev, "^"):
		start = rev
	default:
		start = rev + "^"
	}
	args = []string{"log", fmt.Sprintf("-%d", temporalWindow), "--format=%x00", "--name-only"}
	if start != "" {
		args = append(args, start)
	}
	logs, err := git(root, args...)
	if err != nil {
		return // No history, or a bare first commit: nothing to count.
	}
	changed := map[string]bool{}
	for _, f := range c.Files {
		changed[f] = true
	}
	commits := map[string]int{}
	pairs := map[string]map[string]int{}
	for _, chunk := range strings.Split(logs, "\x00") {
		var files []string
		for _, line := range strings.Split(chunk, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				files = append(files, line)
			}
		}
		if len(files) > temporalWidth {
			continue
		}
		for _, f := range files {
			commits[f]++
		}
		for _, f := range files {
			if !changed[f] {
				continue
			}
			if pairs[f] == nil {
				pairs[f] = map[string]int{}
			}
			for _, g := range files {
				if g != f {
					pairs[f][g]++
				}
			}
		}
	}
	remaining := c.remaining(root, rev, pairs)
	t := &Temporal{Commits: commits, Partners: map[string][]Partner{}}
	for f, ps := range pairs {
		type named struct {
			name string
			j    float64
		}
		list := make([]named, 0, len(ps))
		for name, shared := range ps {
			union := commits[f] + commits[name] - shared
			if union <= 0 {
				continue
			}
			list = append(list, named{name, float64(shared) / float64(union)})
		}
		slices.SortFunc(list, func(a, b named) int {
			if c := cmp.Compare(b.j, a.j); c != 0 {
				return c
			}
			return cmp.Compare(a.name, b.name)
		})
		var partners []Partner
		for _, e := range list {
			if len(partners) == partnerList {
				break
			}
			if remaining[e.name] {
				partners = append(partners, Partner{Name: e.name, Shared: ps[e.name]})
			}
		}
		if len(partners) > 0 {
			t.Partners[f] = partners
		}
	}
	if len(t.Partners) > 0 {
		c.Temporal = t
	}
}

// remaining reports which of the partner paths are still files at the end
// of the change: a partner the tree no longer holds is history's partner,
// not this change's.
func (c *Change) remaining(root, rev string, pairs map[string]map[string]int) map[string]bool {
	out := map[string]bool{}
	tree, err := treeAt(root, rev)
	if err != nil {
		return out
	}
	for _, ps := range pairs {
		for name := range ps {
			if tree.Exists(name) {
				out[name] = true
			}
		}
	}
	return out
}

// shortlist is how many resembling declarations a new name is shown
// beside, ranked; the twins come before them and are not counted.
const shortlist = 12

// findCandidates gathers, for every new name, the existing declarations that
// might already mean the same thing. Finding them is the cheap part; judging
// the shortlist is what the job is for.
func (c *Change) findCandidates(root, rev string, frontends []Frontend) {
	var index []Declared
	for _, f := range frontends {
		if f.Features()&FeatIndex == 0 {
			continue
		}
		declared, err := f.Whole(root, rev)
		if err != nil {
			continue
		}
		index = append(index, declared...)
	}
	c.index = index
	// A constant holding the same literal as a new one is the strongest hint
	// a fact has been written twice, so it goes first where it exists.
	for _, symbol := range c.Symbols {
		var twins []string
		for _, declared := range index {
			if declared.File == symbol.File && declared.Line == symbol.Line {
				continue
			}
			if same(declared, Declared{Text: symbol.Signature}) {
				twins = append(twins, declared.String()+"   <- same value")
			}
		}
		if len(twins) > 0 {
			c.Twins[symbol.Name] = twins
		}
		c.Candidates[symbol.Name] = slices.Concat(twins, Resembling(index, symbol, shortlist))
	}
}

var hunk = regexp.MustCompile(`^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@`)

// diffLine is one added line and the number it lands on in the file the
// change arrives at.
type diffLine struct {
	Line int
	Text string
}

// diffSides splits a diff into the added and removed lines of each file,
// with the added lines' text. The header lines are read wherever they sit,
// as they sit between hunks; the hunk's own content is read only inside a
// hunk, so that a removed line of content beginning "+++ " is not mistaken
// for the header it resembles.
func diffSides(diff string) (added map[string][]diffLine, removed map[string][]string) {
	added = map[string][]diffLine{}
	removed = map[string][]string{}
	var (
		addedFile, removedFile string
		line                   int
		inHunk                 bool
	)
	for _, text := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(text, "+++ "):
			// A deletion names /dev/null, which owns no added lines.
			addedFile = side(text[4:], "b/")
			inHunk = false
		case strings.HasPrefix(text, "--- "):
			// The left side is not being read, but a removed line is
			// only a removed line inside a hunk, so the header is
			// where the removed file is named.
			removedFile = side(text[4:], "a/")
			inHunk = false
		case strings.HasPrefix(text, "\\ "):
			// The no-newline marker annotates the line above it rather than
			// standing for a line of its own.
		case hunk.MatchString(text):
			inHunk = true
			line = atoi(hunk.FindStringSubmatch(text)[1])
		case strings.HasPrefix(text, "+") && inHunk:
			if addedFile != "" {
				added[addedFile] = append(added[addedFile], diffLine{line, strings.TrimPrefix(text, "+")})
			}
			line++
		case strings.HasPrefix(text, "-") && inHunk:
			if removedFile != "" {
				removed[removedFile] = append(removed[removedFile], strings.TrimPrefix(text, "-"))
			}
		default:
			if inHunk {
				line++
			}
		}
	}
	return added, removed
}

// side strips a diff's prefix from a header path, and a deletion's
// /dev/null with it.
func side(path, prefix string) string {
	path = strings.TrimPrefix(path, prefix)
	if path == "/dev/null" {
		return ""
	}
	return path
}

// addedLines reports which lines of which files the diff adds, so that a
// job is shown new work rather than whatever file it landed in.
func addedLines(diff string) map[string][]int {
	added, _ := diffSides(diff)
	out := map[string][]int{}
	for file, lines := range added {
		for _, l := range lines {
			out[file] = append(out[file], l.Line)
		}
	}
	return out
}

func touchedBetween(lines []int, from, to int) bool {
	for _, line := range lines {
		if line >= from && line <= to {
			return true
		}
	}
	return false
}

func text(lines []string, from, to int) string {
	if from < 1 || to > len(lines) {
		return ""
	}
	return strings.Join(lines[from-1:to], "\n")
}

func relative(root, path string) string {
	if rel, err := filepath.Rel(root, path); err == nil {
		return rel
	}
	return path
}

func git(root string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}

// skipLine is the line, within the test's body, on which it skips itself:
// the shapes are t.Skip and its variants in Go, test.skip and it.skip in
// TypeScript, and testing.skip in Odin. Zero when it does not.
func skipLine(t Function) int {
	for i, line := range strings.Split(t.Body, "\n") {
		trimmed := strings.TrimSpace(line)
		for _, shape := range []string{"t.Skip(", "t.Skipf(", "t.SkipNow(", "test.skip(", "it.skip(", "describe.skip(", "this.skip(", "testing.skip(", "t.skip(", "pytest.skip(", "pytest.mark.skip", "self.skipTest(", "unittest.skip"} {
			if strings.Contains(trimmed, shape) {
				return t.Line + i
			}
		}
	}
	return 0
}
