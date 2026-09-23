package check

// The checks here need no model. They measure the commit message and
// report what fails, before anything is asked of a provider and whether or
// not one can answer.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "vendor:zlib"

import "../change"
import "../finding"
import "../txt"

// min_entropy is the Shannon entropy, in bits per byte, under which a
// message is one short phrase said over rather than a description of a
// change. Ordinary commit messages measure between 3.7 and 4.9;
// entropy_floor is the length under which entropy says nothing.
min_entropy   :: 3.2
entropy_floor :: 40

// max_compression is the share of its length a message keeps after zlib,
// under which the message is one block of text pasted or repeated whole.
// No written commit message measured keeps less than 0.26;
// compression_floor is the length under which zlib cannot beat its own
// framing.
max_compression   :: 0.20
compression_floor :: 400

// common_idf is the natural log under which a word counts as one of the
// repository's commonest: it appears in at least a fifth of the subjects.
// history_floor is the number of subjects under which the frequencies are
// too thin to judge a message by.
common_idf    :: 1.6
history_floor :: 100

// digits are the characters whose presence spares a message: a version or
// an issue number is information however few words carry it.
digits :: "0123456789"

// body_floor_lines is the size of diff under which a body is optional;
// max_body_words the length over which a body is listing what the diff
// already shows.
body_floor_lines :: 50
max_body_words   :: 150

// temporal_coupling is the Jaccard over which history says two files
// change together; temporal_support the fewest commits they must share
// before it is a pattern; temporal_findings caps how many pairs one
// change is asked about.
temporal_coupling :: 0.7
temporal_support  :: 5
temporal_findings :: 3

@(private = "file")
venting_words: map[string]bool
@(private = "file")
stop_words: map[string]bool
@(private = "file")
openers: map[string]bool
@(private = "file")
invariant_verbs: map[string]bool
@(private = "file")
irregular_past: map[string]bool
@(private = "file")
non_verb_ing: map[string]bool
@(private = "file")
brands: map[string]bool

@(init)
init_message_words :: proc "contextless" () {
	context = runtime.default_context()
	// The exclamations and profanities of a message written in the moment
	// of the mistake. Every word here is unambiguous: stupid, dumb,
	// finally, eventually and annoying all appear in measured history
	// describing the code legitimately.
	venting_words = set(
		`fuck fucking fucked shit bullshit wtf damn dammit damnit oops oopsie whoops
		ugh argh grr sigh fml yolo idk`,
	)
	// The function words, which name nothing.
	stop_words = set(
		`a an the and or but if then than that this these those
		to of in on at by for with from into up out it its is are was were be been being am
		as so not no nor do does did done doing can could will would shall should may might
		must have has had having i we you they he she him her them his hers their ours your
		my me us what which who whom when where why how all any both each few more most
		other some such only own same too very just also now here there over under again
		further once about between through during before after above below because while
		until against`,
	)
	// The words whose presence alone is narration.
	openers = set(`i we my this these those`)
	// The verbs whose past and imperative share a form.
	invariant_verbs = set(
		`read cut set put let hit cost split shut cast hurt quit burst spread slit`,
	)
	// The past forms no suffix rule could catch.
	irregular_past = set(
		`wrote made kept went got ran brought built bought caught drove found held left met
		paid sent spent took won sold freed`,
	)
	// The words that end in ing without being a verb's gerund.
	non_verb_ing = set(
		`during nothing something anything everything morning evening offing outing bring
		king ring sing spring string swing thing wing cling sting fling`,
	)
	// The product names written with an inner capital.
	brands = set(
		`gRPC iOS macOS iPadOS watchOS tvOS iPhone iPad iCloud eBay jQuery
		PayPal YouTube GitHub GitLab OpenAI WebAssembly LaTeX TeX`,
	)
}

// measured is the message the checks read. It is empty for a staged
// change without a supplied message, and every message check says nothing
// then.
measured :: proc(c: ^change.Change) -> string {
	return strings.trim_space(c.message)
}

// check_entropy reports a message whose characters carry too little
// entropy: the shape of a placeholder, a keyboard mash, or one phrase
// repeated.
check_entropy :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" || len(msg) < entropy_floor {
		return
	}
	h := shannon_entropy(msg)
	if h >= min_entropy {
		return
	}
	append(
		out,
		static(
			"message-low-entropy",
			.Must_Fix,
			fmt.aprintf(
				"the commit message measures %.1f bits of Shannon entropy per byte, under the %.1f beneath which a message is a phrase repeated rather than a description; ordinary messages measure 3.7 to 4.9",
				h,
				min_entropy,
			),
			"write a message that says what the change does and why",
		),
	)
}

// check_compressibility reports a message zlib keeps only a fraction of:
// the shape of text pasted or repeated wholesale, such as a licence notice
// or a log, rather than prose written for this change.
check_compressibility :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" || len(msg) < compression_floor {
		return
	}
	ratio := compression_ratio(msg)
	if ratio >= max_compression {
		return
	}
	append(
		out,
		static(
			"message-boilerplate",
			.Must_Fix,
			fmt.aprintf(
				"the commit message compresses to %.0f%% of its length, under the %.0f%% beneath which it is one block of text pasted or repeated rather than prose about the change; no written message measured keeps less than 26%%",
				100 * ratio,
				100 * max_compression,
			),
			"keep only what the reader needs of the quoted text, and write the rest",
		),
	)
}

// check_common reports a message made entirely of the words this
// repository's own history uses most, which names nothing the change
// touches. A word the history has never used is the one thing a message
// like this cannot have, which is why a message holding any rarer word is
// left to the reader.
check_common :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" || len(s.c.history) < history_floor {
		return
	}
	words := content_words(msg, context.temp_allocator)
	if len(words) == 0 {
		return
	}
	if strings.has_prefix(msg, "Merge ") ||
	   strings.has_prefix(msg, "Squashed ") ||
	   strings.contains_any(msg, digits) {
		return
	}
	freq := frequencies(s.c.history, context.temp_allocator)
	n := len(s.c.history)
	for w in words {
		if math.ln(f64(n) / f64(1 + freq[w])) > common_idf {
			return
		}
	}
	ground := diff_words(s.c, context.temp_allocator)
	for w in words {
		if ground[w] {
			return
		}
	}
	listed := sorted_keys(words)
	append(
		out,
		static(
			"message-common-words",
			.Must_Fix,
			fmt.aprintf(
				"the commit message is made of the repository's commonest commit words — %s — with nothing rarer than a fifth of its %d commit subjects, and it names nothing the change touches; a word the history has not used is the one thing a message like this cannot have",
				strings.join(listed, ", ", context.temp_allocator),
				n,
			),
			"name the part and the fault, in words the change itself uses",
		),
	)
}

// identifier_shaped matches the words of a message that name code rather
// than describe it: a camel-cased or snake-cased word, a dotted or slashed
// path, a call, or anything in backticks.
identifier_shaped :: "`[^`]+`|\\b[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*\\b|\\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\\b|\\b[A-Za-z][A-Za-z0-9_]*\\(\\)|\\b[A-Za-z][A-Za-z0-9_-]*(?:[./][A-Za-z0-9_-]+)+\\.[a-z]{1,5}\\b"

// links matches a URL in a message.
links :: `\bhttps?://\S+`

// check_names_unknown reports a message that names an identifier the
// repository does not hold: not in the diff, not in any file at the end
// of the change, not a path in the tree. A message naming code that is
// not there describes work the diff does not contain.
check_names_unknown :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" {
		return
	}
	msg = remove_all(links, msg, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for m in find_all(identifier_shaped, msg) {
		name := strings.trim_suffix(strings.trim_space(strings.trim(m, "`")), "()")
		if name == "" ||
		   seen[name] ||
		   strings.contains_any(name, " \t") ||
		   strings.contains(name, "://") ||
		   brand_shaped(name) {
			continue
		}
		seen[name] = true
		append(&names, name)
	}
	if len(names) == 0 {
		return
	}
	missing := make([dynamic]string, context.temp_allocator)
	for name in names {
		if strings.contains(s.c.diff, name) || strings.contains(s.c.stat, name) {
			continue
		}
		found := false
		for f in s.files {
			if strings.contains(f, name) {
				found = true
				break
			}
		}
		if !found {
			for _, data in s.sources {
				if strings.contains(string(data), name) {
					found = true
					break
				}
			}
		}
		if !found {
			append(&missing, name)
		}
	}
	if len(missing) == 0 {
		return
	}
	append(
		out,
		static(
			"message-names-unknown",
			.Consider,
			fmt.aprintf(
				"the commit message names %s, and nothing by that name is in the diff or anywhere in the repository at the end of the change; a message naming code that is not there describes work the diff does not contain",
				quoted(missing[:], context.temp_allocator),
			),
			"name what the change actually touches, as the code spells it",
		),
	)
}

// brand_shaped is whether a word is a product name rather than a name
// from the code: on the list, or a short lowercase prefix before a run of
// capitals, which is how gRPC and iOS are spelled and how no identifier
// is.
brand_shaped :: proc(word: string) -> bool {
	if brands[word] {
		return true
	}
	i := 0
	for i < len(word) && word[i] >= 'a' && word[i] <= 'z' {
		i += 1
	}
	if i == 0 || i > 2 || i == len(word) {
		return false
	}
	for j in i ..< len(word) {
		if word[j] < 'A' || word[j] > 'Z' {
			return false
		}
	}
	return true
}

// check_venting reports a message whose words are the author's reaction
// rather than the change's description: oops, whoops, damn, profanity.
check_venting :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" {
		return
	}
	hit := make(map[string]bool, context.temp_allocator)
	for piece in fields(msg, context.temp_allocator) {
		w := strings.to_lower(piece, context.temp_allocator)
		if venting_words[w] {
			hit[w] = true
		}
	}
	if len(hit) == 0 {
		return
	}
	append(
		out,
		static(
			"message-frustration",
			.Must_Fix,
			fmt.aprintf(
				"the commit message is an exclamation — %s — where a description should be; the log then records the author's feeling, and the change goes undescribed",
				strings.join(sorted_keys(hit), ", ", context.temp_allocator),
			),
			"describe the change, not the moment",
		),
	)
}

// check_mood reports a subject that does not open as a command. The
// discipline is package: explainer, with the explainer in the imperative
// mood: a subject that opens in the past tense or on a gerund records
// that a thing was done, and one that opens on the author narrates the
// author. Verbs that wear one form for every mood are spared, as are
// articles: an explainer may be a noun phrase on purpose.
check_mood :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" {
		return
	}
	subject := subject_of(msg)
	if strings.has_prefix(subject, "Merge ") || strings.has_prefix(subject, "Squashed ") {
		return
	}
	words := fields(explainer(subject), context.temp_allocator)
	if len(words) == 0 {
		return
	}
	first := strings.to_lower(words[0], context.temp_allocator)
	what := ""
	switch {
	case openers[first]:
		what = "narration"
	case invariant_verbs[first]:
		return
	case irregular_past[first] ||
	     (len(first) >= 4 && strings.has_suffix(first, "ed") && !strings.has_suffix(first, "eed")):
		what = "the past tense"
	case len(first) >= 5 && strings.has_suffix(first, "ing") && !non_verb_ing[first]:
		what = "a gerund"
	case:
		return
	}
	append(
		out,
		static(
			"message-not-imperative",
			.Must_Fix,
			fmt.aprintf(
				"the commit message opens on %s — %q — where the discipline is a command: package: explainer, with the explainer in the imperative mood; a subject that opens in the past tense, on a gerund, or on the author records what was done rather than saying what to do",
				what,
				words[0],
			),
			"open the subject on its verb, in the imperative",
		),
	)
}

// subject_of is a message's first line.
subject_of :: proc(msg: string) -> string {
	if i := strings.index_byte(msg, '\n'); i >= 0 {
		return msg[:i]
	}
	return msg
}

// explainer is the part of a subject after its package prefix: the part
// after "review:" in "review: measure it". A subject without a lowercase
// prefix is all explainer.
explainer :: proc(subject: string) -> string {
	i := strings.index(subject, ": ")
	if i < 2 || i > 23 {
		return subject
	}
	for j in 0 ..< i {
		r := subject[j]
		if !((r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_') {
			return subject
		}
	}
	return subject[i + 2:]
}

// check_body asks a large change to say something in its body: a diff of
// more than body_floor_lines owes a body, however short, and no body may
// exceed max_body_words. The diff records what moved; the body is the
// only place the change's why is recorded. A change that only moves text
// around, whose subject says what it did, owes nothing.
check_body :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	msg := measured(s.c)
	if msg == "" {
		return
	}
	subject := subject_of(msg)
	if strings.has_prefix(subject, "Merge ") || strings.has_prefix(subject, "Squashed ") {
		return
	}
	n := body_words(msg)
	if n > max_body_words {
		append(
			out,
			static(
				"message-long-body",
				.Must_Fix,
				fmt.aprintf(
					"the commit message's body holds %d words, over the %d the discipline allows; past that a body lists what the diff already shows, and the reader of the log stops before the why",
					n,
					max_body_words,
				),
				"cut the body to the change's why",
			),
		)
		return
	}
	if n > 0 {
		return
	}
	changed := changed_lines(s.c.diff)
	if changed <= body_floor_lines || moved(s.c.diff) {
		return
	}
	append(
		out,
		static(
			"message-no-body",
			.Must_Fix,
			fmt.aprintf(
				"the change is %d lines of diff, and the commit message carries no body; the diff records what moved, and the body is the only place the change's why is recorded",
				changed,
			),
			"write the body, saying why the change is what it is",
		),
	)
}

// check_temporal reports a changed file whose history names a partner the
// change does not touch: over the last thousand commits before the
// change, at least temporal_coupling of the commits touching either file
// have touched both, at least temporal_support times. Files that change
// together this reliably usually fail together.
check_temporal :: proc(s: Scope, out: ^[dynamic]finding.Finding) {
	temporal, counted := s.c.temporal.?
	if !counted {
		return
	}
	changed := make(map[string]bool, context.temp_allocator)
	for f in s.c.files {
		changed[f] = true
	}
	Pair :: struct {
		file:    string,
		partner: change.Partner,
		joint:   int,
		j:       f64,
	}
	pairs := make([dynamic]Pair, context.temp_allocator)
	for file, partners in temporal.partners {
		for p in partners {
			if changed[p.name] {
				continue
			}
			joint := temporal.commits[file] + temporal.commits[p.name] - p.shared
			if joint <= 0 {
				continue
			}
			j := f64(p.shared) / f64(joint)
			if j < temporal_coupling {
				// The list is nearest first, so the rest of this file's
				// partners are further away still.
				break
			}
			if p.shared < temporal_support {
				continue
			}
			append(&pairs, Pair{file, p, joint, j})
		}
	}
	slice.sort_by_cmp(pairs[:], proc(a, b: Pair) -> slice.Ordering {
		if a.partner.shared != b.partner.shared {
			return .Less if a.partner.shared > b.partner.shared else .Greater
		}
		if a.j != b.j {
			return .Less if a.j > b.j else .Greater
		}
		if a.file != b.file {
			return .Less if a.file < b.file else .Greater
		}
		if a.partner.name != b.partner.name {
			return .Less if a.partner.name < b.partner.name else .Greater
		}
		return .Equal
	})
	for p, i in pairs {
		if i == temporal_findings {
			break
		}
		append(
			out,
			static(
				"history-coupled-file",
				.Must_Fix,
				fmt.aprintf(
					"history ties %s to %s: %d of the %d commits touching either file have touched both, and this change touches %s without %s; files that change together this reliably usually fail together, and the half of the pair left out is where a forgotten change usually is",
					p.file,
					p.partner.name,
					p.partner.shared,
					p.joint,
					p.file,
					p.partner.name,
				),
				fmt.aprintf(
					"touch %s too, or be sure it stands without this change",
					p.partner.name,
				),
				file = p.file,
			),
		)
	}
}

// moved is whether a diff's added and removed sides hold the same lines:
// the change rearranged text rather than changing it.
moved :: proc(diff: string) -> bool {
	counts := make(map[string]int, context.temp_allocator)
	n := 0
	rest := diff
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "+") && !strings.has_prefix(line, "-") {
			continue
		}
		if strings.has_prefix(line, "+++") || strings.has_prefix(line, "---") {
			continue
		}
		s := strings.trim_space(line[1:])
		if s == "" {
			continue
		}
		n += 1
		counts[s] += 1 if line[0] == '+' else -1
	}
	for _, v in counts {
		if v != 0 {
			return false
		}
	}
	return n > 0
}

// body_words counts the words below the subject line.
body_words :: proc(msg: string) -> int {
	i := strings.index_byte(msg, '\n')
	if i < 0 {
		return 0
	}
	return len(fields(msg[i + 1:], context.temp_allocator))
}

// changed_lines counts the lines a diff adds or removes, without the
// diff's own framing.
changed_lines :: proc(diff: string) -> int {
	n := 0
	rest := diff
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "+") && !strings.has_prefix(line, "-") {
			continue
		}
		if strings.has_prefix(line, "+++") || strings.has_prefix(line, "---") {
			continue
		}
		n += 1
	}
	return n
}

// content_words is the vocabulary of a text: lowercased, split on
// anything that is not a letter or digit, split again at camel humps,
// depluralised, and stripped of the words that name nothing.
content_words :: proc(text: string, allocator := context.allocator) -> map[string]bool {
	out := make(map[string]bool, allocator)
	for piece in fields(text, context.temp_allocator) {
		for part in humps(piece, context.temp_allocator) {
			w := txt.depluralise(strings.to_lower(part, allocator))
			if len(w) > 2 && !stop_words[w] {
				out[w] = true
			}
		}
	}
	return out
}

// humps splits containerSniff into container and sniff, so that a message
// naming a thing meets the identifier for it in the diff.
humps :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	start := 0
	prev_lower := false
	for r, i in s {
		upper := r >= 'A' && r <= 'Z'
		if i > 0 && upper && prev_lower {
			append(&out, s[start:i])
			start = i
		}
		prev_lower = r >= 'a' && r <= 'z'
	}
	if start < len(s) {
		append(&out, s[start:])
	}
	return out[:]
}

// frequencies counts, over the repository's subjects, in how many of them
// each content word appears.
frequencies :: proc(history: []string, allocator := context.allocator) -> map[string]int {
	out := make(map[string]int, allocator)
	for s in history {
		for w in content_words(s, allocator) {
			out[w] += 1
		}
	}
	return out
}

// diff_words is the vocabulary of what a change touches: the file paths,
// and the words of every line it adds or removes.
diff_words :: proc(c: ^change.Change, allocator := context.allocator) -> map[string]bool {
	out := make(map[string]bool, allocator)
	for path in c.files {
		stem := path
		if dot := strings.last_index_byte(path, '.'); dot > strings.last_index_byte(path, '/') {
			stem = path[:dot]
		}
		for w in content_words(stem, allocator) {
			out[w] = true
		}
	}
	rest := c.diff
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "+++") ||
		   strings.has_prefix(line, "---") ||
		   strings.has_prefix(line, "@@") ||
		   strings.has_prefix(line, "diff ") ||
		   strings.has_prefix(line, "index ") ||
		   strings.has_prefix(line, "\\ ") {
			continue
		}
		if strings.has_prefix(line, "+") || strings.has_prefix(line, "-") {
			for w in content_words(line[1:], allocator) {
				out[w] = true
			}
		}
	}
	return out
}

// shannon_entropy is the entropy of s in bits per byte, over its bytes.
shannon_entropy :: proc(s: string) -> f64 {
	n := len(s)
	if n == 0 {
		return 0
	}
	counts: [256]int
	for i in 0 ..< n {
		counts[s[i]] += 1
	}
	h: f64
	for c in counts {
		if c == 0 {
			continue
		}
		p := f64(c) / f64(n)
		h -= p * math.log2(p)
	}
	return h
}

// compression_ratio is the share of its length s keeps after zlib, at
// the library's default level, which is the ratio the threshold was
// measured with.
compression_ratio :: proc(s: string) -> f64 {
	if len(s) == 0 {
		return 1
	}
	bound := zlib.compressBound(zlib.uLong(len(s)))
	dest := make([]byte, int(bound), context.temp_allocator)
	dest_len := zlib.uLongf(bound)
	source := transmute([]byte)s
	if zlib.compress2(raw_data(dest), &dest_len, raw_data(source), zlib.uLong(len(s)), -1) != 0 {
		return 1
	}
	return f64(dest_len) / f64(len(s))
}
