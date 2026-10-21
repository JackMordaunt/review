# Odin procedure design

Judge changed Odin procedures against these rules. Whole bodies provide context;
report only problems introduced by the listed added lines. A finding must name the
concrete operation, its use and lifetime, and a workable correction.

- `odin-avoidable-allocation` — avoid runtime allocation when the procedure can
  reasonably use caller storage, a local value or a fixed stack buffer. Establish
  why the value stays within that lifetime before recommending replacement. A
  returned or retained value, unbounded data, or a library contract requiring
  allocated storage can justify allocation. Temporary allocators still allocate
  at runtime; changing allocator alone does not remove an allocation.
- `odin-bounded-temporary-string` — a short temporary string used only within the
  procedure should use a stack-buffer API when one fits the operation. Ordinary
  environment variables are a concrete case: consider a buffer around 512 bytes
  and `os.lookup_env(buffer[:], key)`, checking its `.Buffer_Full` error.
  Do not use the buffer form of `os.get_env` where it hides this error.
  The buffer size is an ordinary
  case optimisation, not an input limit: oversized values must have an explicit,
  correct fallback or error, never silent truncation or changed semantics. Do not
  flag an environment value that escapes the buffer lifetime, nor invent an API
  or recommend a stack buffer without a safe overflow policy.
- `odin-allocator-contract` — a procedure that uses an allocator must expose an
  allocator parameter, so its signature advertises that dependency and lets the
  caller override it. A default such as `allocator := context.allocator` is
  allowed. The supplied allocator must govern the relevant operations, either
  passed to callees or installed in the procedure's local context; an unused
  parameter does not satisfy the rule. Temporary or internally constructed
  allocators do not make the dependency disappear. Cover allocating calls whose
  contracts are established by the supplied evidence, and exposed parameters
  bypassed by hard-coded allocators. Do not guess allocation from a callee's name
  alone. A fixed entry-point or callback signature should delegate allocating
  work to a helper with an allocator parameter. Report a demonstrated contract
  violation as must-fix. Explicit allocation without an allocator parameter is
  already checked by `odin-allocator-parameter`; do not duplicate that finding.
- `odin-allocator-consistency` — storage must be freed or resized with the
  allocator that allocated it. Report must-fix only when the shown allocation,
  release or resize, and allocator values establish a mismatch for the same
  object. Follow explicit arguments, context changes and simple allocator copies;
  different identifier names or context fields alone do not prove inequality.
  Dynamic arrays, maps and dynamic SOA containers retain their allocator, so a
  later context change does not retarget their delete, reserve or resize.
  Pointer, slice and string releases may instead use an explicit allocator or
  the current context. Resolve the actual operation; do not guess an overload
  or treat a shadowed builtin as the runtime operation. Unknown identity is not
  a finding, and free_all is an allocator reset rather than an object's free.
  This inference rule does not repeat missing-parameter or avoidable-allocation
  findings; it concerns mismatched allocator use even when allocation is needed
  and the signature already exposes an allocator.
- `odin-borrowed-retention` — report must-fix when the shown code proves a
  pointer, slice or string outlives its backing storage: a returned stack
  pointer, a retained argument with an established retention contract, or a
  borrow used after its exact owner is freed or its temporary allocator resets.
  A callee name alone does not prove retention. A temporary allocation returned
  without a reset here is not automatically dangling; establish the lifetime.
  Copies, enduring storage and unknown ownership do not trigger this rule.
  Do not repeat local-array slice/string returns reported by
  `odin-borrowed-escape`; this rule covers the remaining proven lifetime cases.
- `odin-thick-entrypoint` — the main package in a cmd subtree only bootstraps context and
  debug allocator tracking where appropriate, delegates to other packages, then
  handles shutdown or exit. Report application logic or argument dispatch in main
  or its package-local helpers; moving logic to a helper in package main does not
  establish a package boundary. Necessary
  context setup, allocator cleanup and forwarding the exit result are allowed.
- `odin-domain-cli-parsing` — one package named cli owns mapping command-line
  strings to domain procedure calls. Domain packages accept typed domain inputs
  and do not interpret flags, positional command words or process argument lists.
  Judge semantic command dispatch that structural checks cannot recognize. A
  domain parser reading a data format or a domain string is not command-line
  parsing merely because the caller obtained it from an argument. A library with
  no command-line interface needs no cli package. Do not infer a missing package
  or multiple cli packages from an incomplete view of the repository.

Entry-point location, duplicate cli packages and direct use of known argument
parsing APIs outside cli are measured before this reading; do not report those
again. Do not report an allocation under both allocation rules. Use
`odin-bounded-temporary-string` for the short-string case and
`odin-avoidable-allocation` for other demonstrably avoidable storage.

If the supplied bodies omit a callee's ownership contract or overflow behaviour,
report nothing based on that uncertainty. Do not turn an allocation preference
into a requirement to remove justified heap storage. Prefer severity consider
for a demonstrated avoidable allocation; reserve must-fix for concrete lifetime,
truncation or architecture violations.
