package main

// The checks here need no model. They measure the commit message and report
// what fails, before anything is asked of a provider and whether or not one
// can answer. A check that passes says nothing.

import (
	"bytes"
	"cmp"
	"compress/zlib"
	"fmt"
	"math"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode"
)

// Check measures a change and reports what it noticed.
type Check func(*Change) []Finding

// Checks are the deterministic readings, each independent of the others:
// the message, the history, the review's own mechanisms, and then the code
// the change adds — its names, tests, bodies, comments and leftovers.
func Checks() []Check {
	return []Check{
		checkEntropy, checkCompressibility, checkCommon, checkVenting, checkMood, checkBody, checkFormatting, checkNamesUnknown,
		checkTemporal,
		checkSuppressionAdded, checkDeletedTests,
		checkNames, checkTestAssertions, checkTautologies, checkClones, checkShape,
		checkRestating, checkTodos, checkCommentedCode, checkDebugLeftovers, checkSwallowedErrors,
		checkUnreferenced, checkCodeWithoutTests,
	}
}

const (
	// minEntropy is the Shannon entropy, in bits per byte, under which a
	// message is one short phrase said over rather than a description of a
	// change. Ordinary commit messages measure between 3.7 and 4.9.
	minEntropy = 3.2

	// entropyFloor is the message length under which entropy says nothing: a
	// subject of a dozen characters is low-entropy whatever it says.
	entropyFloor = 40

	// maxCompression is the share of its length a message keeps after zlib,
	// under which the message is one block of text pasted or repeated whole.
	// No written commit message measured keeps less than 0.26.
	maxCompression = 0.20

	// compressionFloor is the message length under which zlib cannot beat its
	// own framing, and the ratio means nothing.
	compressionFloor = 400

	// commonIDF is the natural log under which a word counts as one of the
	// repository's commonest: a word this common appears in at least a fifth
	// of the repository's commit subjects, however many there are.
	commonIDF = 1.6

	// historyFloor is the number of commit subjects under which the word
	// frequencies are too thin to judge a message by, and the check says
	// nothing.
	historyFloor = 100

	// digits are the characters whose presence spares a message: a version
	// or an issue number is information however few words carry it.
	digits = "0123456789"

	// bodyFloorLines is the size of diff, in changed lines, under which a
	// body is optional: the subject may say enough by itself.
	bodyFloorLines = 50

	// maxBodyWords is the length, in words, over which a body is listing
	// what the diff already shows rather than explaining the change.
	maxBodyWords = 150

	// temporalCoupling is the Jaccard over which history says two files
	// change together: over the counted commits, at least this share of the
	// commits touching either file touches both. Measured fire rates: 12%
	// of sampled commits at 0.5, 3.6% at 0.7, and the pairs the higher
	// threshold keeps are the changed-without-its-test kind.
	temporalCoupling = 0.7

	// temporalSupport is the fewest commits two files must share before
	// their history is a pattern rather than a coincidence.
	temporalSupport = 5

	// temporalFindings caps how many pairs one change is asked about, so a
	// change grazing five coupled files starts one conversation, not five.
	temporalFindings = 3
)

// ventingWords are the exclamations and profanities of a message written in
// the moment of the mistake rather than about the change. Every word here
// is unambiguous: stupid, dumb, finally, eventually and annoying all appear
// in measured history describing the code legitimately, so they are not
// here.
var ventingWords = map[string]bool{
	"fuck": true, "fucking": true, "fucked": true,
	"shit": true, "bullshit": true, "wtf": true,
	"damn": true, "dammit": true, "damnit": true,
	"oops": true, "oopsie": true, "whoops": true,
	"ugh": true, "argh": true, "grr": true, "sigh": true,
	"fml": true, "yolo": true, "idk": true,
}

// runChecks applies every check. It is called before any provider is built,
// so what the checks find is reported whether or not a model can be asked.
func runChecks(change *Change) []Finding {
	var out []Finding
	for _, check := range Checks() {
		out = append(out, check(change)...)
	}
	return out
}

// checkEntropy reports a message whose characters carry too little entropy:
// the shape of a placeholder, a keyboard mash, or one phrase repeated.
func checkEntropy(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	if len(msg) < entropyFloor {
		return nil
	}
	h := shannonEntropy(msg)
	if h >= minEntropy {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "message-low-entropy", Severity: MustFix,
		Message: fmt.Sprintf(
			"the commit message measures %.1f bits of Shannon entropy per byte, under the %.1f beneath which a message is a phrase repeated rather than a description; ordinary messages measure 3.7 to 4.9",
			h, minEntropy),
		Fix: "write a message that says what the change does and why",
	}}
}

// checkCompressibility reports a message zlib keeps only a fraction of: the
// shape of text pasted or repeated wholesale, such as a licence notice or a
// log, rather than prose written for this change.
func checkCompressibility(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	if len(msg) < compressionFloor {
		return nil
	}
	ratio := compressionRatio(msg)
	if ratio >= maxCompression {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "message-boilerplate", Severity: MustFix,
		Message: fmt.Sprintf(
			"the commit message compresses to %.0f%% of its length, under the %.0f%% beneath which it is one block of text pasted or repeated rather than prose about the change; no written message measured keeps less than 26%%",
			100*ratio, 100*maxCompression),
		Fix: "keep only what the reader needs of the quoted text, and write the rest",
	}}
}

// checkCommon reports a message made entirely of the words this
// repository's own history uses most, which names nothing the change
// touches. A word the history has never used is the one thing a message
// like this cannot have, which is why a message holding any rarer word is
// left to the reader.
func checkCommon(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	if len(c.History) < historyFloor {
		return nil
	}
	words := contentWords(msg)
	if len(words) == 0 {
		return nil
	}
	if strings.HasPrefix(msg, "Merge ") || strings.HasPrefix(msg, "Squashed ") ||
		strings.ContainsAny(msg, digits) {
		return nil
	}
	freq := frequencies(c.History)
	n := len(c.History)
	for w := range words {
		if math.Log(float64(n)/float64(1+freq[w])) > commonIDF {
			return nil
		}
	}
	ground := diffWords(c)
	for w := range words {
		if ground[w] {
			return nil
		}
	}
	listed := make([]string, 0, len(words))
	for w := range words {
		listed = append(listed, w)
	}
	slices.Sort(listed)
	return []Finding{{
		Job: "static", Rule: "message-common-words", Severity: MustFix,
		Message: fmt.Sprintf(
			"the commit message is made of the repository's commonest commit words — %s — with nothing rarer than a fifth of its %d commit subjects, and it names nothing the change touches; a word the history has not used is the one thing a message like this cannot have",
			strings.Join(listed, ", "), n),
		Fix: "name the part and the fault, in words the change itself uses",
	}}
}

// identifierShaped matches the words of a message that name code rather
// than describe it: a camel-cased or snake-cased word, a dotted or slashed
// path, a call, or anything in backticks.
var identifierShaped = regexp.MustCompile("`([^`]+)`|\\b([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)\\b|\\b([A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+)\\b|\\b([A-Za-z][A-Za-z0-9_]*\\(\\))|\\b([A-Za-z][A-Za-z0-9_-]*(?:[./][A-Za-z0-9_-]+)+\\.[a-z]{1,5})\\b")

// links matches a URL in a message.
var links = regexp.MustCompile(`\bhttps?://\S+`)

// checkNamesUnknown reports a message that names an identifier the
// repository does not hold: not in the diff, not in any file at the end of
// the change, not a path in the tree. A message naming code that is not
// there describes work the diff does not contain — usually a name remembered
// wrong, sometimes a change that was never made.
func checkNamesUnknown(c *Change) []Finding {
	msg := measured(c)
	if msg == "" || c.root == "" {
		return nil
	}
	// A link's path is not a name the message uses.
	msg = links.ReplaceAllString(msg, " ")
	var names []string
	seen := map[string]bool{}
	for _, m := range identifierShaped.FindAllStringSubmatch(msg, -1) {
		name := ""
		for _, group := range m[1:] {
			if group != "" {
				name = group
			}
		}
		name = strings.TrimSuffix(strings.TrimSpace(name), "()")
		if name == "" || seen[name] || strings.ContainsAny(name, " \t") || strings.Contains(name, "://") || brandShaped(name) {
			continue
		}
		seen[name] = true
		names = append(names, name)
	}
	if len(names) == 0 {
		return nil
	}
	tree, err := treeAt(c.root, c.rev)
	if err != nil {
		return nil
	}
	sources, err := tree.Sources()
	if err != nil {
		return nil
	}
	files, _ := tree.Files()
	var missing []string
	for _, name := range names {
		if strings.Contains(c.Diff, name) || strings.Contains(c.Stat, name) {
			continue
		}
		found := false
		for _, f := range files {
			if strings.Contains(f, name) {
				found = true
				break
			}
		}
		for _, data := range sources {
			if found {
				break
			}
			if strings.Contains(string(data), name) {
				found = true
			}
		}
		if !found {
			missing = append(missing, name)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "message-names-unknown", Severity: Consider,
		Message: fmt.Sprintf("the commit message names %s, and nothing by that name is in the diff or anywhere in the repository at the end of the change; a message naming code that is not there describes work the diff does not contain", quoted(missing)),
		Fix:     "name what the change actually touches, as the code spells it",
	}}
}

// brands are the product names written with an inner capital, which the
// identifier shape mistakes for camel case. Measured: gRPC was the first.
var brands = set(`gRPC iOS macOS iPadOS watchOS tvOS iPhone iPad iCloud eBay jQuery
	PayPal YouTube GitHub GitLab OpenAI WebAssembly LaTeX TeX`)

// brandShaped is whether a word is a product name rather than a name from
// the code: on the list, or a short lowercase prefix before a run of
// capitals, which is how gRPC and iOS are spelled and how no identifier is;
// macOS is longer and on the list.
func brandShaped(word string) bool {
	if brands[word] {
		return true
	}
	i := 0
	for i < len(word) && word[i] >= 'a' && word[i] <= 'z' {
		i++
	}
	if i == 0 || i > 2 || i == len(word) {
		return false
	}
	for _, r := range word[i:] {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

// quoted joins names for a message, each in quotes.
func quoted(names []string) string {
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = fmt.Sprintf("%q", n)
	}
	return strings.Join(out, ", ")
}

// checkVenting reports a message whose words are the author's reaction
// rather than the change's description: oops, whoops, damn, profanity.
func checkVenting(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	var hit []string
	for _, piece := range fields(msg) {
		w := strings.ToLower(piece)
		if ventingWords[w] {
			hit = append(hit, w)
		}
	}
	if len(hit) == 0 {
		return nil
	}
	slices.Sort(hit)
	hit = slices.Compact(hit)
	return []Finding{{
		Job: "static", Rule: "message-frustration", Severity: MustFix,
		Message: fmt.Sprintf(
			"the commit message is an exclamation — %s — where a description should be; the log then records the author's feeling, and the change goes undescribed",
			strings.Join(hit, ", ")),
		Fix: "describe the change, not the moment",
	}}
}

// checkMood reports a subject that does not open as a command. The
// discipline is package: explainer, with the explainer in the imperative
// mood: a subject that opens in the past tense or on a gerund records that
// a thing was done, and one that opens on the author narrates the author.
// The suffix rules cannot hear an adjective from a past participle, and
// verbs that wear one form for every mood are spared, as are articles: an
// explainer may be a noun phrase on purpose, as the tool's own subjects
// are.
func checkMood(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	subject := strings.SplitN(msg, "\n", 2)[0]
	if strings.HasPrefix(subject, "Merge ") || strings.HasPrefix(subject, "Squashed ") {
		return nil
	}
	words := fields(explainer(subject))
	if len(words) == 0 {
		return nil
	}
	first, quoted := strings.ToLower(words[0]), words[0]
	what := ""
	switch {
	case openers[first]:
		what = "narration"
	case invariantVerbs[first]:
		return nil
	case irregularPast[first] || (len(first) >= 4 && strings.HasSuffix(first, "ed") &&
		!strings.HasSuffix(first, "eed")):
		what = "the past tense"
	case len(first) >= 5 && strings.HasSuffix(first, "ing") && !nonVerbIng[first]:
		what = "a gerund"
	default:
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "message-not-imperative", Severity: MustFix,
		Message: fmt.Sprintf(
			"the commit message opens on %s — %q — where the discipline is a command: package: explainer, with the explainer in the imperative mood; a subject that opens in the past tense, on a gerund, or on the author records what was done rather than saying what to do",
			what, quoted),
		Fix: "open the subject on its verb, in the imperative",
	}}
}

// explainer is the part of a subject after its package prefix: explainer is
// the part after "review:" in "review: measure it". A subject without a
// lowercase prefix is all explainer.
func explainer(subject string) string {
	i := strings.Index(subject, ": ")
	if i < 2 || i > 23 {
		return subject
	}
	for _, r := range subject[:i] {
		if !('a' <= r && r <= 'z' || '0' <= r && r <= '9' || r == '-' || r == '_') {
			return subject
		}
	}
	return subject[i+2:]
}

// openers are the words whose presence alone is narration: the author as
// subject, and the demonstratives of "this fixes".
var openers = map[string]bool{
	"i": true, "we": true, "my": true,
	"this": true, "these": true, "those": true,
}

// invariantVerbs are the verbs whose past and imperative share a form, such
// as read and set: a subject opening on one is a command until the
// sentence says otherwise, and the suffix rules cannot hear which.
var invariantVerbs = map[string]bool{
	"read": true, "cut": true, "set": true, "put": true, "let": true,
	"hit": true, "cost": true, "split": true, "shut": true, "cast": true,
	"hurt": true, "quit": true, "burst": true, "spread": true, "slit": true,
}

// irregularPast are the past forms that no suffix rule could catch, which
// cannot be imperatives because their imperatives are other words.
var irregularPast = map[string]bool{
	"wrote": true, "made": true, "kept": true, "went": true, "got": true,
	"ran": true, "brought": true, "built": true, "bought": true, "caught": true,
	"drove": true, "found": true, "held": true, "left": true, "met": true,
	"paid": true, "sent": true, "spent": true, "took": true, "won": true,
	"sold": true, "freed": true,
}

// nonVerbIng are the words that end in ing without being a verb's gerund.
var nonVerbIng = map[string]bool{
	"during": true, "nothing": true, "something": true, "anything": true,
	"everything": true, "morning": true, "evening": true, "offing": true,
	"outing": true, "bring": true, "king": true, "ring": true, "sing": true,
	"spring": true, "string": true, "swing": true, "thing": true, "wing": true,
	"cling": true, "sting": true, "fling": true,
}

// checkBody asks a large change to say something in its body: a diff of
// more than bodyFloorLines owes a body, however short, and no body may
// exceed maxBodyWords. The diff records what moved; the body is the only
// place the change's why is recorded. The diff's size is a weak measure of
// how much a change needs saying — a small diff can hold the subtle fault,
// a large one can be a formatting run — so the check asks only for
// existence, and a change that only moves text around, whose subject says
// what it did, owes nothing. Subjects of merges and squashes are git's
// words, not the commit's.
func checkBody(c *Change) []Finding {
	msg := measured(c)
	if msg == "" {
		return nil
	}
	subject := strings.SplitN(msg, "\n", 2)[0]
	if strings.HasPrefix(subject, "Merge ") || strings.HasPrefix(subject, "Squashed ") {
		return nil
	}
	n := bodyWords(msg)
	if n > maxBodyWords {
		return []Finding{{
			Job: "static", Rule: "message-long-body", Severity: MustFix,
			Message: fmt.Sprintf(
				"the commit message's body holds %d words, over the %d the discipline allows; past that a body lists what the diff already shows, and the reader of the log stops before the why",
				n, maxBodyWords),
			Fix: "cut the body to the change's why",
		}}
	}
	if n > 0 {
		return nil
	}
	changed := changedLines(c.Diff)
	if changed <= bodyFloorLines || moved(c.Diff) {
		return nil
	}
	return []Finding{{
		Job: "static", Rule: "message-no-body", Severity: MustFix,
		Message: fmt.Sprintf(
			"the change is %d lines of diff, and the commit message carries no body; the diff records what moved, and the body is the only place the change's why is recorded",
			changed),
		Fix: "write the body, saying why the change is what it is",
	}}
}

// checkTemporal reports a changed file whose history names a partner the
// change does not touch: over the last thousand commits before the change,
// at least temporalCoupling of the commits touching either file have
// touched both, at least temporalSupport times. A coupling like that is
// not the compiler's to see, and only the author can say whether the pair
// still changes together; files that change together this reliably usually
// fail together.
func checkTemporal(c *Change) []Finding {
	if c.Temporal == nil {
		return nil
	}
	changed := map[string]bool{}
	for _, f := range c.Files {
		changed[f] = true
	}
	type pair struct {
		file    string
		partner Partner
		union   int
		j       float64
	}
	var pairs []pair
	for file, partners := range c.Temporal.Partners {
		for _, p := range partners {
			if changed[p.Name] {
				continue
			}
			union := c.Temporal.Commits[file] + c.Temporal.Commits[p.Name] - p.Shared
			if union <= 0 {
				continue
			}
			j := float64(p.Shared) / float64(union)
			if j < temporalCoupling {
				// The list is nearest first, so the rest of this file's
				// partners are further away still.
				break
			}
			if p.Shared < temporalSupport {
				continue
			}
			pairs = append(pairs, pair{file, p, union, j})
		}
	}
	slices.SortFunc(pairs, func(a, b pair) int {
		if c := cmp.Compare(b.partner.Shared, a.partner.Shared); c != 0 {
			return c
		}
		if c := cmp.Compare(b.j, a.j); c != 0 {
			return c
		}
		if c := cmp.Compare(a.file, b.file); c != 0 {
			return c
		}
		return cmp.Compare(a.partner.Name, b.partner.Name)
	})
	if len(pairs) > temporalFindings {
		pairs = pairs[:temporalFindings]
	}
	findings := make([]Finding, 0, len(pairs))
	for _, p := range pairs {
		findings = append(findings, Finding{
			Job: "static", Rule: "history-coupled-file", Severity: MustFix,
			File: p.file,
			Message: fmt.Sprintf(
				"history ties %s to %s: %d of the %d commits touching either file have touched both, and this change touches %s without %s; files that change together this reliably usually fail together, and the half of the pair left out is where a forgotten change usually is",
				p.file, p.partner.Name, p.partner.Shared, p.union, p.file, p.partner.Name),
			Fix: fmt.Sprintf("touch %s too, or be sure it stands without this change", p.partner.Name),
		})
	}
	return findings
}

// moved is whether a diff's added and removed sides hold the same lines:
// the change rearranged text rather than changing it. Whitespace may be
// load-bearing in a few languages; the exemption errs toward silence, as
// the others do.
func moved(diff string) bool {
	counts := map[string]int{}
	n := 0
	for _, line := range strings.Split(diff, "\n") {
		if !strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "-") {
			continue
		}
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") {
			continue
		}
		s := strings.TrimSpace(line[1:])
		if s == "" {
			continue
		}
		n++
		if strings.HasPrefix(line, "+") {
			counts[s]++
		} else {
			counts[s]--
		}
	}
	for _, v := range counts {
		if v != 0 {
			return false
		}
	}
	return n > 0
}

// bodyWords counts the words below the subject line.
func bodyWords(msg string) int {
	parts := strings.SplitN(msg, "\n", 2)
	if len(parts) == 1 {
		return 0
	}
	return len(fields(parts[1]))
}

// changedLines counts the lines a diff adds or removes, without the diff's
// own framing. A diff truncated by the packet's cap undercounts, which
// asks less of the body and errs toward silence.
func changedLines(diff string) int {
	n := 0
	for _, line := range strings.Split(diff, "\n") {
		if !strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "-") {
			continue
		}
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") {
			continue
		}
		n++
	}
	return n
}

// contentWords is the vocabulary of a text: lowercased, split on anything
// that is not a letter or digit, split again at camel humps, depluralised,
// and stripped of the words that name nothing.
func contentWords(text string) map[string]bool {
	out := map[string]bool{}
	for _, piece := range fields(text) {
		for _, part := range humps(piece) {
			w := depluralise(strings.ToLower(part))
			if len(w) > 2 && !stopWords[w] {
				out[w] = true
			}
		}
	}
	return out
}

// fields splits on anything that is not a letter or a digit.
func fields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

// stopWords are the function words, which name nothing: both a message and
// the change it describes are full of them.
var stopWords = map[string]bool{}

func init() {
	for _, w := range strings.Fields(`a an the and or but if then than that this these those
		to of in on at by for with from into up out it its is are was were be been being am
		as so not no nor do does did done doing can could will would shall should may might
		must have has had having i we you they he she him her them his hers their ours your
		my me us what which who whom when where why how all any both each few more most
		other some such only own same too very just also now here there over under again
		further once about between through during before after above below because while
		until against`) {
		stopWords[w] = true
	}
}

// humps splits containerSniff into container and sniff, so that a message
// naming a thing meets the identifier for it in the diff.
func humps(s string) []string {
	var out []string
	var cur strings.Builder
	rs := []rune(s)
	for i, r := range rs {
		if i > 0 && unicode.IsUpper(r) && unicode.IsLower(rs[i-1]) {
			out = append(out, cur.String())
			cur.Reset()
		}
		cur.WriteRune(r)
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// depluralise drops a trailing s, except where dropping it would leave
// another: class stays class.
func depluralise(w string) string {
	if len(w) > 3 && strings.HasSuffix(w, "s") && w[len(w)-2] != 's' {
		return w[:len(w)-1]
	}
	return w
}

// frequencies counts, over the repository's subjects, in how many of them
// each content word appears.
func frequencies(history []string) map[string]int {
	out := map[string]int{}
	for _, s := range history {
		for w := range contentWords(s) {
			out[w]++
		}
	}
	return out
}

// diffWords is the vocabulary of what a change touches: the file paths, and
// the words of every line it adds or removes, so that a message naming its
// ground meets the ground it names.
func diffWords(c *Change) map[string]bool {
	out := map[string]bool{}
	for _, path := range c.Files {
		for w := range contentWords(strings.TrimSuffix(path, filepath.Ext(path))) {
			out[w] = true
		}
	}
	for _, line := range strings.Split(c.Diff, "\n") {
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") ||
			strings.HasPrefix(line, "@@") || strings.HasPrefix(line, "diff ") ||
			strings.HasPrefix(line, "index ") || strings.HasPrefix(line, "\\ ") {
			continue
		}
		if strings.HasPrefix(line, "+") || strings.HasPrefix(line, "-") {
			for w := range contentWords(line[1:]) {
				out[w] = true
			}
		}
	}
	return out
}

// measured is the message the checks read. It is empty for a staged change
// without a supplied message, and every message check says nothing then:
// there is no message to measure, and the previous commit's is not it.
func measured(c *Change) string {
	return strings.TrimSpace(c.Message)
}

// shannonEntropy is the entropy of s in bits per byte, over its bytes. A
// message holding runes outside ASCII measures higher than its characters
// alone would, which errs toward silence.
func shannonEntropy(s string) float64 {
	n := len(s)
	if n == 0 {
		return 0
	}
	var counts [256]int
	for i := range n {
		counts[s[i]]++
	}
	var h float64
	for _, c := range counts {
		if c == 0 {
			continue
		}
		p := float64(c) / float64(n)
		h -= p * math.Log2(p)
	}
	return h
}

// compressionRatio is the share of its length s keeps after zlib. The
// framing counts, which is why the check applies only past compressionFloor.
func compressionRatio(s string) float64 {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	w.Write([]byte(s))
	w.Close()
	return float64(buf.Len()) / float64(len(s))
}
