package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
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
	// Message is the commit message under review.
	Message string
	// Stat is the per-file line counts, which is enough to notice a commit
	// doing two things without reading either.
	Stat string
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
	// Convention is the recent commit subjects, so a job can read the local
	// habit rather than impose one.
	Convention []string
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
}

// Function is a whole function, which the test job needs because a test can
// only be judged by what it asserts.
type Function struct {
	Name string `json:"name"`
	File string `json:"file"`
	Line int    `json:"line"`
	Body string `json:"body"`
}

// Located is a line of prose and where it came from.
type Located struct {
	Text string `json:"text"`
	File string `json:"file"`
	Line int    `json:"line"`
}

// maxDiff caps what is sent. A change larger than this is reviewed by its
// parts rather than badly as a whole.
const maxDiff = 60000

// at reads a file as it stands at a revision, so that reviewing an old commit
// reads the code that commit left behind rather than whatever the working
// tree holds now.
func at(root, rev, path string) ([]byte, error) {
	if rev == "" {
		return os.ReadFile(filepath.Join(root, path))
	}
	// A..B is reviewed as B, which is the state the change arrived at.
	if _, after, found := strings.Cut(rev, ".."); found {
		rev = after
	}
	cmd := exec.Command("git", "show", rev+":"+path)
	cmd.Dir = root
	return cmd.Output()
}

// Gather collects the change at a revision range, or the staged change when
// the range is empty.
func Gather(rev string, root string) (*Change, error) {
	var diffArgs, nameArgs, statArgs []string
	switch rev {
	case "":
		diffArgs = []string{"diff", "--cached", "-U3"}
		nameArgs = []string{"diff", "--cached", "--name-only"}
		statArgs = []string{"diff", "--cached", "--stat"}
	default:
		diffArgs = []string{"diff", rev, "-U3"}
		nameArgs = []string{"diff", rev, "--name-only"}
		statArgs = []string{"diff", rev, "--stat"}
	}

	change := &Change{Candidates: map[string][]string{}}
	var err error
	if change.Diff, err = git(root, diffArgs...); err != nil {
		return nil, err
	}
	if len(change.Diff) > maxDiff {
		change.Diff = change.Diff[:maxDiff] + "\n… diff truncated\n"
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
	if rev == "" {
		change.Message, _ = git(root, "log", "-1", "--format=%B")
		change.Message = "(uncommitted; the message below is the previous commit's)\n" + change.Message
	} else {
		change.Message, _ = git(root, "log", "-1", "--format=%B", strings.TrimSuffix(rev, "^"))
	}
	if subjects, err := git(root, "log", "-12", "--format=%s"); err == nil {
		for _, s := range strings.Split(strings.TrimSpace(subjects), "\n") {
			if s != "" {
				change.Convention = append(change.Convention, s)
			}
		}
	}

	change.read(root, rev)
	change.findCandidates(root, rev)
	return change, nil
}

// read pulls the declarations, tests and prose out of the files the change
// touches. Only what the diff added is reported, so a job sees new work
// rather than the file it landed in.
func (c *Change) read(root, rev string) {
	added := addedLines(c.Diff)
	for _, name := range c.Files {
		if !strings.HasSuffix(name, ".go") {
			continue
		}
		source, err := at(root, rev, name)
		if err != nil {
			continue // Deleted by the change, so there is nothing to read.
		}
		path := filepath.Join(root, name)
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, source, parser.ParseComments)
		if err != nil {
			continue
		}
		lines := strings.Split(string(source), "\n")
		touched := added[name]

		ast.Inspect(file, func(n ast.Node) bool {
			switch decl := n.(type) {
			case *ast.FuncDecl:
				line := fset.Position(decl.Pos()).Line
				end := fset.Position(decl.End()).Line
				if !touchedBetween(touched, line, end) {
					return true
				}
				name := decl.Name.Name
				if strings.HasPrefix(name, "Test") || strings.HasPrefix(name, "Fuzz") || strings.HasPrefix(name, "Benchmark") {
					c.Tests = append(c.Tests, Function{
						Name: name, File: relative(root, path), Line: line,
						Body: text(lines, line, end),
					})
					return true
				}
				c.Symbols = append(c.Symbols, Symbol{
					Name: name, Kind: "func", Doc: doc(decl.Doc),
					File: relative(root, path), Line: line,
					Exported: ast.IsExported(name), Signature: strings.TrimSpace(lines[line-1]),
				})
			case *ast.TypeSpec:
				line := fset.Position(decl.Pos()).Line
				if !slices.Contains(touched, line) {
					return true
				}
				c.Symbols = append(c.Symbols, Symbol{
					Name: decl.Name.Name, Kind: "type", File: relative(root, path), Line: line,
					Exported: ast.IsExported(decl.Name.Name), Signature: strings.TrimSpace(lines[line-1]),
				})
			case *ast.ValueSpec:
				for _, ident := range decl.Names {
					line := fset.Position(ident.Pos()).Line
					if !slices.Contains(touched, line) {
						continue
					}
					c.Symbols = append(c.Symbols, Symbol{
						Name: ident.Name, Kind: "value", File: relative(root, path), Line: line,
						Exported: ast.IsExported(ident.Name), Signature: strings.TrimSpace(lines[line-1]),
					})
				}
			}
			return true
		})

		for _, group := range file.Comments {
			for _, comment := range group.List {
				line := fset.Position(comment.Pos()).Line
				if !slices.Contains(touched, line) {
					continue
				}
				c.Comments = append(c.Comments, Located{
					Text: strings.TrimSpace(strings.TrimPrefix(comment.Text, "//")),
					File: relative(root, path), Line: line,
				})
			}
		}
	}
}

// findCandidates gathers, for every new name, the existing declarations that
// might already mean the same thing. Finding them is the cheap part; judging
// the shortlist is what the job is for.
func (c *Change) findCandidates(root, rev string) {
	index, err := Index(root, rev)
	if err != nil {
		return
	}
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
		c.Candidates[symbol.Name] = append(twins, Resembling(index, symbol, 16)...)
	}
}

var hunk = regexp.MustCompile(`^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@`)

// addedLines reports which lines of which files the diff adds, so that a job
// is shown new work rather than whatever file it landed in.
func addedLines(diff string) map[string][]int {
	out := map[string][]int{}
	var (
		file string
		line int
	)
	for _, text := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(text, "+++ b/"):
			file = strings.TrimPrefix(text, "+++ b/")
		case hunk.MatchString(text):
			line = atoi(hunk.FindStringSubmatch(text)[1])
		case strings.HasPrefix(text, "+") && file != "":
			out[file] = append(out[file], line)
			line++
		case strings.HasPrefix(text, "-"):
		default:
			line++
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

func doc(group *ast.CommentGroup) string {
	if group == nil {
		return ""
	}
	return strings.TrimSpace(group.Text())
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
