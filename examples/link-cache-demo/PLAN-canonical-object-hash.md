# Plan: canonical-hash `.o` files in the cache key

> **Status: ❌ Investigated, ruled out as unsound.** Kept for the
> record. A naïve canonicalisation that sorts the symbol table and
> rewrites relocations by symbol name (the obvious approach,
> sketched below in the "proposed fix" section) collapses two `.o`
> files that the linker would treat as **semantically distinct**
> into the same cache key — see "Why this can't work as planned"
> at the bottom of this doc for the worked example from hydra's
> `Hydra/Prelude.o`. A sound version would require GHC's codegen
> to be deterministic in the affected sections, which is a GHC
> change, not a cache-side one.

A second cache-side lever uncovered by the hydra A/B work (after
[`PLAN-exe-link-cache.md`](PLAN-exe-link-cache.md) closed the
single biggest one).

## TL;DR

- **Today.** The link-cache hashes `.o` file bytes directly. Two
  `.o` files that the linker would treat as semantically equivalent
  (same symbols, same code, same relocations) but that have
  non-deterministic byte differences (mostly: UNDEFINED-symbol
  ordering in the `.symtab`/`.strtab`) hash to different cache
  keys → MISS.
- **Why it matters.** On hydra's `add-unexported/hydra-node`, the
  one missed lib archive (`libHShydra-prelude-2.1.0-inplace.a`)
  cascades to **5+ exe misses** because the exe links include the
  edited lib's archive in their cache key. If the lib's
  archive HIT, those exes would also HIT — potentially adding
  another ~5–10s to revert-style speedups on top of what the
  exe-link cache already delivers.
- **Proposed.** Replace direct byte-hashing of `.o` files (and
  archives composed of them) with a *canonical* hash that's
  invariant under benign symbol-table reordering. Specifically:
  hash a normal form built from `(text, data, rodata, …) +
  sorted(symtab_by_name) + relocations_referenced_by_symbol_name`
  rather than the file bytes.

## Motivating evidence (root-cause walk on hydra)

`scripts/link-cache-compare.sh` against `hydra-node` with
`02-add-unexported.patch`. After my exe-link work the cache
shape is:

```
17 HITs, 6 misses per build:
- HIT: every library .so + most library .a
- HIT: every test-lib .a
- MISS: libHShydra-prelude-2.1.0-inplace.a        ← the edited lib
- MISS: hydra-node, tx-cost, tests, micro, logging ← exes depending on it
```

Investigating the lone lib MISS:

1. `Hydra/Prelude.dyn_o` is byte-identical between baseline and
   post-edit (`.so` HITs).
2. `Hydra/Prelude.o` differs by 30 bytes (`.a` misses).
3. `nm` reports the same 178 symbols in both `.o`s.
4. `readelf --syms` shows two GLOBAL UNDEFINED symbols swapping
   positions:
   - baseline: `[32] prettyzmsimplezm…`, `[33] prettyprinterzma…`
   - post-edit: `[32] prettyprinterzma…`, `[33] prettyzmsimplezm…`
5. The differing bytes (offsets 15793, 20790-20809) land inside
   `.symtab` and `.strtab`. The byte diff is **just** that
   reordering plus its echo in the string table.

The two `.o`s are *semantically equivalent* from the linker's
point of view: same code, same exported symbols, same UND symbols.
But the byte-hash treats them as distinct → MISS → 5+ cascading
exe misses.

## The proposed fix

Compute a canonical hash that treats two `.o`s as equal iff a
linker would produce identical bytes from them.

For ELF (the only format we need to support initially — Linux is
the primary target, macOS / Windows can keep using direct
byte-hashing):

1. Parse the ELF header.
2. For each section that affects linker output (`.text`,
   `.data`, `.rodata*`, `.bss`, `.note*`, `.comment`, `.tdata`,
   `.tbss`, weak/init/fini sections), hash the bytes as-is and
   include `(section_name, bytes_hash)` in the canonical form.
3. For `.symtab`:
   - Resolve each entry's `st_name` against `.strtab` to get the
     actual symbol string.
   - Sort entries lexicographically by name.
   - For each entry, include `(name, st_value, st_size, st_info,
     st_other, target_section_name_or_UND)` in the canonical
     form. Drop `st_shndx` (a numeric section index) in favour of
     the section name (which is stable across section reordering
     too).
4. For each `.rela.*` / `.rel.*` section:
   - For each relocation, resolve the symbol index back to a
     name via the canonical symtab order.
   - Include `(parent_section_name, r_offset, symbol_name,
     r_type, r_addend)` in the canonical form.
5. Drop `.shstrtab` and `.strtab` from the hash — they are
   regenerable bookkeeping.
6. Hash the resulting normal form with `xxh3` and use that in
   place of the direct file-byte hash for cache-key purposes.

The on-disk `.o` file is **not** modified — only the cache-key
digest changes. Targets, blobs, and verify-mode behaviour are
unaffected.

For `.a` archives, hash the canonical form of each member `.o`
file in sorted-by-name order. (cabal already wipes `ar` metadata
via `wipeMetadata`, so once we canonicalise the members the
archive's contribution to the cache key is fully byte-stable
under symbol-reorder noise.)

## Implementation steps

1. New module `Distribution.Simple.GHC.LinkManifest.Canonical`
   (or extend `LinkManifest` directly) with:
   - `canonicalObjectHash :: FilePath -> IO XXH3Hash`
   - `canonicalArchiveHash :: FilePath -> IO XXH3Hash` (calls
     `canonicalObjectHash` on each member)
   - Falls back to plain byte-hashing on non-ELF inputs (Mach-O,
     COFF, raw `.a` from a different toolchain).

2. ELF parsing: prefer a small inline parser (no new dep) over
   pulling in `elf-edit` / `data-elf`. The format is regular and
   we only need the section table + the symtab/strtab/rela
   layout. ~150–200 lines of `ByteString` arithmetic.

3. Integrate into `cachedLink`'s key computation: where today
   we have `hashOf inputs`, route `.o` and `.a` inputs through
   `canonicalObjectHash` / `canonicalArchiveHash`. Other input
   types (e.g. linker scripts) keep direct hashing.

4. Gate behind `CABAL_LINK_CACHE_CANONICAL=1` initially so it's
   experimental — flip the default to ON after a release of
   wide use. Default to OFF for the first release, with
   instructions in the README.

5. Verify-mode soundness: every canonical-HIT must re-run the
   linker and byte-match the cached blob. This is the existing
   `CABAL_LINK_CACHE_VERIFY=1` path; no new infrastructure
   needed. Run the bench's `--verify` sweep with canonical
   mode on and confirm no `HIT-DIVERGED`.

6. New cabal-testsuite fixture: `LinkCacheCanonical` that hand-
   constructs two `.o` files differing only in symbol order and
   asserts they HIT each other under canonical mode (but MISS
   each other under the default byte-hash mode).

## Risks and mitigations

- **ELF parsing bugs.** Misreading section headers or symbol
  table entries could produce wrong canonical hashes → false HITs
  → wrong linker output. Mitigation: keep the parser narrow
  (read only the fields we need), property-test against
  hand-constructed inputs, gate behind the env var until proven.
  Verify mode catches divergences in CI / user runs.
- **Cross-toolchain compatibility.** GHC versions, gold vs
  bfd vs lld, glibc vs musl, sanitiser-enabled builds — all can
  produce different ELF section layouts. The canonical form
  needs to be conservative (skip only known-equivalence-preserving
  differences). When in doubt, hash the bytes.
- **Mach-O / COFF.** macOS and Windows users don't get the win
  unless we add parsers for those formats. Fallback to byte-hash
  is sound (no win, no regression).
- **Performance.** Canonical hashing reads + parses every `.o`
  on the first cache key computation. The byte-hash path is
  ~5–10x faster (just streams bytes through xxh3). For warm
  builds with the stat-index short-circuit, parsing cost is
  amortised across many lookups; for cold builds it's per-file.
  Expected overhead: 5–20ms per `.o`, so a project with 5000 `.o`
  files might see ~50s of additional cold-build hashing. Worth
  measuring before defaulting to ON.

## Expected gain

- **Demo (`examples/link-cache-demo/`)**: **none.** The original
  draft of this section assumed `whitespace-only` / `comment-only`
  / `reorder-exports` / `refactor-internal` had `.o` line-number
  shifts that a canonical hash could collapse. Those scenarios
  turned out to already HIT 9/9 once the bench's between-iter
  contamination was fixed (Finding 3 retracted, see
  `INVESTIGATION.md`). The demo no longer motivates this work.
- **Hydra (`add-unexported/hydra-node`)**: was the remaining
  motivator — converting the lone lib MISS (and its 5 cascading
  exe misses) into HITs. Estimated additional ~10–20% speedup on
  top of the current +22% the exe-link cache delivers.

## Future work (out of scope)

- **Canonicalise debug sections.** `.debug_line`, `.debug_info`,
  `.debug_aranges` contain source file paths and line-number
  tables. Theoretically these could shift on whitespace/comment
  edits in builds that include debug info; in practice GHC's
  default `-O1` codegen on this demo doesn't emit `.debug_*`
  sections that vary, which is why the line-shift scenarios
  HIT 9/9 without any canonicalisation.
- **Mach-O parser** (macOS) and **PE/COFF parser** (Windows).
  Each is ~200–300 lines. Defer until there's a user reporting
  the asymmetric behaviour on those platforms.
- **Hash incremental updates.** When the same `.o` is hashed in
  N different cache lookups in a single build, canonical
  parsing happens N times. Cache the canonical hash per-process
  (we already do this for byte-hashes via the stat-index;
  extend it). Cheap follow-up.

## Why this can't work as planned

The plan above assumed that two `.o` files differing only in
symbol-table order would also have semantically-equivalent
`.rela.*` sections — i.e., once you resolve relocation entries by
symbol name instead of by index, the canonical forms would agree.

That assumption holds for `.rela.text` on the hydra `Prelude.o`
case (verified: canonical `.rela.text` is byte-identical between
the two `.o` files). It does **not** hold for `.rela.data`.

In the hydra `02-add-unexported.patch` rebuild, the swapped symbol
ordering ripples into the `.data` layout itself:

```
< 000000000048  001700000001 R_X86_64_64  base_GHCziIOziExc[...] + 0
< 000000000050  001200000001 R_X86_64_64  hydrazmpreludezm2[...] + 0
---
> 000000000048  001200000001 R_X86_64_64  hydrazmpreludezm2[...] + 0
> 000000000050  001700000001 R_X86_64_64  base_GHCziIOziExc[...] + 0
```

i.e. baseline writes `&base_GHCziIOziExc` at `.data + 0x48` and
`&hydrazmpreludezm…` at `.data + 0x50`; the post-edit build swaps
which pointer lands at which offset. The final linked binary's
`.data` bytes at those positions are **different**.

The cache key has to reflect that difference — otherwise a HIT
would produce a binary with `.data[0x48]` and `.data[0x50]`
pointing at the wrong symbols, and verify-mode would flag every
such HIT as `HIT-DIVERGED`. Sound caching means the canonical
hash MUST differ between these two `.o` files.

The deeper cause is GHC non-determinism in the *order* it emits
top-level closures into `.data` (and the corresponding relocation
entries into `.rela.data`). On the same source GHC produces two
byte-different but semantically-equivalent layouts; on a tiny
source edit it produces a third layout where the swapped order
shows up as a `.rela.data` diff that is **load-bearing for the
linker output**.

There is no cache-side fix that recovers HITs here without
introducing unsoundness. The fix has to come from GHC: emit
`.data` closures in a deterministic order (e.g., sorted by
mangled name, or in source-order) so byte-equivalent rebuilds
produce byte-equivalent `.o` files.

## Disposition

- The fork's cache is unchanged: `.o` files continue to be
  hashed by raw bytes, preserving the existing soundness story.
- The hydra cascade (`add-unexported/hydra-node` → 5 cascading
  exe misses) is now a known *GHC non-determinism* issue, not a
  cache one. File upstream against GHC: "`.data` closure ordering
  is non-deterministic between rebuilds of byte-stable
  interfaces, causing downstream caches to MISS on what would
  otherwise be byte-equal inputs".
- An implementation of canonical hashing exists as
  experimental Haskell on the `Hydra/Prelude.o` test case — see
  the `canonicalElf64ForHash` function's history in this
  repository (removed because it didn't actually fix the hydra
  cascade and added 200 lines of unused ELF-parsing code). Sorted
  by name + relocation-by-name still left the canonical forms
  byte-different because of the `.rela.data` semantic
  divergence above.

## What we'd still want, if GHC fixes its side

If GHC's `.data` codegen becomes deterministic (or the cache
gains a different shape — e.g., output-keyed dedup that re-runs
the linker before HIT), the canonical-`.o` work becomes
worthwhile again. The remaining cabal-side levers would then
be:

1. The same canonical-ELF parser sketched above (still ~150
   lines, but now correct).
2. Caching the `ar` archive by member-content rather than by
   archive bytes, so the lib `.a` HITs whenever its `.o`
   members hash the same.
3. A cabal-testsuite fixture (`LinkCacheCanonical`) hand-
   constructing two byte-different-but-semantically-equivalent
   `.o` files and asserting they HIT each other in canonical
   mode.
