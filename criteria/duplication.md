# Duplication

You are given each name the change adds, and a list of existing declarations found by
searching for its words. Decide whether the new thing already exists.

- `already-named` — the repository already has a name for this concept. A second
  name for one idea is worse than an awkward first one.
- `restates-a-fact` — a constant or literal states something already stated
  elsewhere: the same magic bytes, the same size, the same layout, written twice.
  Facts belong to one owner.
- `in-the-stdlib` — the standard library already defines this. A hand-copied
  constant (`0x2000` for `IMAGE_FILE_DLL`) is the common case.
- `layout-crosses-a-seam` — one package states the byte layout, field order or
  wire format that another package owns. A size constant describing a structure
  another package reads or writes is the usual shape of it. The owner should
  expose it.

An error value is the exception to all of these. A package declares its own
sentinels so that its callers can test for them without importing somewhere else,
and that is part of its interface however identical the text is. Never report one
error value as a duplicate of another.

## The pass to make

Before judging anything, list the declarations that have a candidate marked
`<- same value`. Then judge every entry on that list, including the ones that come
after the first duplicate you find. Stopping early because a duplicate has already
been reported is the mistake this job makes most often.

A declaration with several same-value candidates is judged against each of them in
turn, and each pair that survives is its own finding.

For each pair, say what the two values measure, then compare the answers:

- Both measure the same field of the same structure — the same header, the same
  directory row, the same signature, the same magic. One fact with two owners:
  report it, and say which declaration should own it.
- One identifies and the other measures — a resource type id beside a row width, a
  count beside a byte size, an index beside a length. Different facts that happen to
  be equal: say nothing about them.

A header size and another package's directory size that are equal because they
describe the same header are the case this job exists for. Report each such pair
separately, one finding each.

Only report when the candidate list actually contains the thing. You cannot see the
whole repository, so do not guess that something exists somewhere. If the candidates
do not show a duplicate, report nothing.

## Reading across languages

The repository's declarations arrive read by the language's own grammar, so a
name is found however it is laid out and a constant's value is compared
whether the line says `=` or `::`. The error-value exception above is a Go and
TypeScript shape: a package owns its sentinels. A language that reports errors
by returning them has nothing of that shape to skip.
