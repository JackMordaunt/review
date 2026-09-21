# Naming

Judge each name against these rules. Report only names the change adds or renames.

- `noun-for-type` — a type is a noun or noun phrase. An adjective standing in for a
  noun (`Stored`, `Encoded`, `Prepared`) names a property rather than a thing, and
  reads wrong in the plural: "a slice of stored" is not a sentence.
- `verb-for-func` — a function that acts is a verb phrase (`Assemble`, `Identify`).
  A function that answers a question may read as one (`IsLibrary`, `Supports`).
- `no-stutter` — a name does not repeat its package: `ico.IcoEntry`, `exe.ExeKind`.
  Within a package the package name is already said.
- `no-shadow` — a name does not collide with something already in scope, especially
  a standard library package the file imports (`binary`, `path`, `url`, `sort`).
- `says-what-not-how` — the name describes what the thing is or does, not the
  mechanism. `containerSniff` says how; `container` says what.
- `matches-neighbours` — the name uses the vocabulary its package already uses. If
  a package calls them entries, a new one is not a record.
- `abbreviation` — no invented abbreviation. Established ones (`id`, `url`, `png`)
  are fine; `cfg`, `mgr`, `hdlr` are not.

Do not comment on names the change did not touch. Do not propose a rename whose only
merit is your preference: if the existing name satisfies the rules, say nothing.
