# Link-output cache: future directions

This is a design note about extensions to the content-addressed link
cache implemented in `Distribution.Simple.GHC.LinkManifest`. Nothing
here is implemented today; the file exists so the choices we did
make are not quietly precluding the choices we might want to make
later.

For the design as actually shipped, see `Note [Link manifest cache]`
in `Distribution.Simple.GHC.Build.Link`.

## Where we are today

The cache is single-rooted, per-user, content-keyed by:

* tool identifier (e.g. `"ar-static"`, `"ghc-link-exe"`),
* target file basename, and
* sorted xxh64 digests of every link input.

The 16-char xxh64 hex digests are concatenated with the tool/name
prefix and MD5'd to produce the final 32-char cache key. xxh64 is
chosen for input hashing because hashing the link inputs is the
dominant cost on cold caches and xxh64 is roughly 5-10x faster than
MD5; the final MD5 of the keyBytes is cheap regardless.

Sharing scope:

* Two checkouts of the same project on the same user account share
  cached outputs automatically. That works because the key omits
  the target's directory path, and modern cabal RPATHs are written
  as `$ORIGIN` / `@loader_path`-relative, so the linker output is
  byte-identical between same-shape checkouts.
* No other sharing happens. Different users, different machines,
  and CI runners all see independent caches.

Eviction is FIFO by mtime ("oldest first") under a configurable byte
cap (`CABAL_LINK_CACHE_MAX_BYTES`, default 5 GiB). Hits bump the
blob's mtime so the FIFO becomes effectively LRU.

## Cross-user sharing on a single machine

Plausible for trusted multi-user CI hosts and developer workstations
with multiple build accounts.

Sketch:

1. Cache root pluggable to a system-wide directory, e.g.
   `/var/cache/cabal/link-cache/`, with permissions `drwxrwxrwt`
   (sticky world-writable, like `/tmp`).
2. Each blob and manifest written by `(uid, mode 0644)` so other
   users can read but only the original writer can overwrite or
   delete. Sticky bit prevents other users from deleting either.
3. GC pass becomes opportunistic per-user: a user can only evict
   their own entries. A long-lived shared store should run a
   privileged GC daemon to handle global cap enforcement; this is
   out of scope for cabal itself.
4. `CABAL_LINK_CACHE_DIR` already provides the override point. No
   code change to lib:Cabal is required for opt-in --- the
   distribution provides the dir, the user sets the env var.

Risks:

* `umask` discipline: a write done with `umask 077` will be
  unreadable to others. The cache writer needs to either widen the
  permissions explicitly (`chmod 0644` after rename) or document
  the requirement.
* World-writable dirs are an old-style attack surface. The blob
  contents are byte-identical for matching inputs, so cross-user
  read isn't a confidentiality concern, but a malicious user could
  fill the cache or trigger DoS via the GC pass. The privileged GC
  daemon mitigates.

## Cross-machine / nix-style sharing

Distinctly more ambitious: a content-addressed store accessible from
multiple machines, with cryptographic provenance.

Sketch A --- nix store integration:

1. Each blob is realised as a nix store path
   `/nix/store/<hash>-link-output-<basename>`. The `<hash>` is
   derived from `(tool, sorted input nar hashes)`, mirroring how
   nix already content-addresses build outputs.
2. The cache lookup becomes `nix-store -r /nix/store/...`. Substitution
   from a binary cache (e.g. `cache.nixos.org`) makes this transparent
   for popular outputs.
3. Signing: only blobs signed by a configured trusted key are
   accepted from a remote substituter. Locally-built blobs are
   trusted unconditionally.

Sketch B --- bespoke HTTP cache, no nix:

1. `CABAL_LINK_CACHE_REMOTE=https://...` registers a read-only
   upstream. On a local miss, we GET
   `<upstream>/blobs/<key>.blob` and `<upstream>/manifests/<key>.manifest`.
2. Each manifest carries a detached signature; we verify against a
   pre-configured public key before trusting the blob.
3. Local cache stays writable; remote is read-only and per-CI
   provisioned.

Either sketch requires confidence that `(tool, target basename,
input bytes)` is a sound content key. We don't have that confidence
today --- foreign-lib determinism in particular is uncharacterised.
The `CABAL_LINK_CACHE_VERIFY=1` mode added alongside the cache is
the data-gathering tool: a periodic canary CI run with VERIFY=1
will flag any tool whose output drifts under byte-equal inputs.

We should not enable cross-machine sharing until at least three
months of VERIFY canary data shows no HIT-DIVERGED lines across the
intended toolchain matrix.

## Why we copy instead of hardlink on HIT

A tempting optimisation for the HIT-not-already-current path: replace
`atomicCopy blobPath target` with a hardlink so the target and the
blob share an inode. For a 20MB exe this trades a few tens of ms of
data movement for ~zero wall-clock.

We don't do this because in-place mutation of the target by user
tools (`strip`, the macOS code signer, a debugger-symbol rewriter)
would corrupt the cached blob: any future HIT would byte-copy the
mutated bytes back. The stamp would still claim the original key,
so the divergence wouldn't even register without a VERIFY canary.

`reflink(2)` (FICLONE / FICLONERANGE on btrfs/XFS) sidesteps this
with copy-on-write semantics but requires a syscall binding we
don't currently have. `copy_file_range` would be faster than naive
read/write but still produces an independent file (which is what we
want); a future change can route through it on Linux.

In practice the HIT-already-current path (where the target is
already byte-equal to the blob via the stamp short-circuit) covers
the common case and is sub-ms anyway, so the savings on
HIT-not-already-current would be modest even before the
strip-footgun.

## What we explicitly do not do

* **Trust unsigned blobs from a network cache.** Any cross-machine
  sharing must either (a) be a content-addressed substituter (e.g.
  nix) with cryptographic signing, or (b) re-verify the output
  locally before reuse. Mirroring a tarball of someone else's
  `~/.cache/cabal/link-cache/` is not OK.
* **Replicate the GHC build cache.** GHC already caches `.o`/`.hi`
  inside the dist directory by source-mtime; lib:Cabal's link
  cache is strictly downstream of that and only kicks in once GHC
  has produced the link inputs. The two systems compose --- we
  should not try to unify them.
* **Mutate cached blobs.** A blob is immutable for the life of its
  key. Anything that wants to repair or reformat the on-disk
  representation should bump the key (e.g. via a `--v2` suffix on
  filenames) and let the GC reclaim the old ones.
