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
  wire format that another package owns. The owner should expose it.

Only report when the candidate list actually contains the thing. You cannot see the
whole repository, so do not guess that something exists somewhere. If the candidates
do not show a duplicate, report nothing.
