#!/usr/bin/env bash
# Diff the inputs of two link-cache manifests for a given target.
#
# Two ways to invoke:
#
#   1. Direct: two manifest files
#        scripts/link-cache-manifest-diff.sh A.manifest B.manifest
#
#   2. Cache dir + target basename: locates the manifest(s) that
#      describe targets whose full path ends in BASENAME. Useful when
#      a cache dir contains both baseline and perturbed manifests for
#      the same target (e.g. after a novel-edit cache-on run).
#
#        scripts/link-cache-manifest-diff.sh --cache=DIR \
#            --target=libHSdemo-core-0.1.0.0-inplace.a
#
#      With --target, the helper picks the two newest manifests
#      matching the target and diffs them oldest→newest.
#
# Manifest format (Cabal/src/Distribution/Simple/GHC/LinkManifest.hs:574-585):
#
#     tool: <tool>
#     target: <abs-path>
#     created: <timestamp>
#     inputs:
#       <digest>  <basename>
#       ...
#
# Output is the symmetric difference of the (basename, digest) pairs,
# annotated as ADD / DEL / CHG, plus a final "unchanged: N" line.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0"
}

CACHE=""
TARGET=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache=*)  CACHE="${1#*=}"; shift ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do FILES+=("$1"); shift; done ;;
    *)  FILES+=("$1"); shift ;;
  esac
done

resolve_files() {
  if [[ -n "$CACHE" && -n "$TARGET" ]]; then
    [[ -d "$CACHE" ]] || { echo "error: --cache dir not found: $CACHE" >&2; exit 2; }
    # Find manifests whose 'target:' line ends in the requested basename.
    mapfile -t matches < <(
      grep -l "target: .*/${TARGET}$" "$CACHE"/*.manifest 2>/dev/null \
        | xargs -r ls -t  # newest first
    )
    if (( ${#matches[@]} < 2 )); then
      echo "error: need at least 2 manifests for target $TARGET in $CACHE" >&2
      echo "       found ${#matches[@]}" >&2
      exit 2
    fi
    # Pick the newest two; diff older → newer.
    FILES=( "${matches[1]}" "${matches[0]}" )
  fi
  if (( ${#FILES[@]} != 2 )); then
    echo "error: expected exactly two manifest files (or --cache + --target)" >&2
    usage >&2
    exit 2
  fi
  for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "error: manifest not found: $f" >&2; exit 2; }
  done
}

# Extract (basename, digest) pairs from a manifest. Manifest format
# has inputs as "  <digest>  <basename>" lines after the "inputs:"
# marker.
extract_inputs() {
  awk '
    /^inputs:/ { in_inputs = 1; next }
    in_inputs && NF == 2 { print $2 "\t" $1 }
  ' "$1"
}

resolve_files

OLD="${FILES[0]}"
NEW="${FILES[1]}"

echo "old: $OLD"
echo "new: $NEW"
echo "---"

OLD_TMP="$(mktemp)"; NEW_TMP="$(mktemp)"
trap 'rm -f "$OLD_TMP" "$NEW_TMP"' EXIT
extract_inputs "$OLD" | sort > "$OLD_TMP"
extract_inputs "$NEW" | sort > "$NEW_TMP"

# Build a unified view of (basename, old_digest, new_digest).
join -t $'\t' -a1 -a2 -e '-' -o '0,1.2,2.2' "$OLD_TMP" "$NEW_TMP" \
  | awk -F'\t' '
      $2 == "-"               { printf("ADD  %-50s  -                 → %s\n", $1, $3); next }
      $3 == "-"               { printf("DEL  %-50s  %s → -\n",                 $1, $2); next }
      $2 != $3                { printf("CHG  %-50s  %s → %s\n",                $1, $2, $3); changed++; next }
                              { same++ }
      END {
        printf("\nunchanged: %d\n", same+0)
        printf("changed:   %d\n",   changed+0)
      }
    '
