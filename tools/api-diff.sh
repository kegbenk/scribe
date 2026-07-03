#!/usr/bin/env bash
#
# api-diff.sh — diff the PUBLIC API surface of the Scribe library between two git refs.
#
# Usage:
#   tools/api-diff.sh [OLD_REF] [NEW_REF]
#
#   OLD_REF defaults to the most recent tag reachable from HEAD (git describe).
#   NEW_REF defaults to HEAD.
#
# Examples:
#   tools/api-diff.sh 0.3.0 HEAD      # what changed since the 0.3.0 release
#   tools/api-diff.sh                 # last tag .. HEAD
#
# What it does
#   For each ref it checks the tree out into a throwaway `git worktree`, extracts
#   every `public`/`open` declaration from swift/Sources/Scribe/*.swift, normalizes
#   the signatures (drops bodies, comments, and line numbers; sorts), and diffs the
#   two normalized sets. Removed/renamed lines (a `-` in the diff) are potential
#   BREAKING changes; added lines (`+`) are additive.
#
# Exit codes
#   0  no public symbols were removed (additive-only or no change)
#   1  one or more public symbols were removed/renamed (review as a breaking change)
#   2  usage / internal error
#
# LIMITATIONS (pragmatic, source-grep based — not a type-aware ABI checker)
#   * It matches declarations by a normalized source signature line. A change to a
#     symbol's `@available` attribute (which lives on the preceding line) or to a
#     parameter default value is NOT detected. Reordering parameters IS detected
#     (the signature string changes).
#   * It only inspects swift/Sources/Scribe/*.swift (the published library target,
#     per the root Package.swift). It does not inspect the CLI target.
#   * `public` symbols nested inside a `private`/`internal` type are still listed;
#     Swift access control means they are not actually reachable, but in this repo
#     top-level library types are `public`, so this is not a practical concern.
#   * For a fully type-aware diff, swap the extractor for
#     `xcrun swift-api-digester -dump-sdk`; that needs a built module and is heavier.
#     This grep form is intentionally dependency-free and fast.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_SUBPATH="swift/Sources/Scribe"

OLD_REF="${1:-}"
NEW_REF="${2:-HEAD}"

if [[ -z "$OLD_REF" ]]; then
  OLD_REF="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -z "$OLD_REF" ]]; then
    echo "error: no tag found to diff against; pass OLD_REF explicitly" >&2
    exit 2
  fi
fi

# Normalize a Scribe source tree into a sorted list of public signatures.
# $1 = path to a checkout's swift/Sources/Scribe dir
extract_public_api() {
  local dir="$1"
  # Grab declaration lines that expose public/open API. Strip trailing bodies at
  # the first `{`, collapse whitespace, drop comments, then sort-unique.
  grep -rhoE '^[[:space:]]*(public|open)[[:space:]]+[^{]*' "$dir"/*.swift 2>/dev/null \
    | sed -E 's/[[:space:]]*\/\/.*$//; s/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | grep -vE '^(public|open)$' \
    | sort -u
}

work_old="$(mktemp -d)"
work_new="$(mktemp -d)"
cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$work_old" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree remove --force "$work_new" 2>/dev/null || true
  rm -rf "$work_old" "$work_new"
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add --detach --quiet "$work_old" "$OLD_REF"
git -C "$REPO_ROOT" worktree add --detach --quiet "$work_new" "$NEW_REF"

api_old="$(mktemp)"
api_new="$(mktemp)"
extract_public_api "$work_old/$SRC_SUBPATH" > "$api_old"
extract_public_api "$work_new/$SRC_SUBPATH" > "$api_new"

echo "Scribe public API diff: $OLD_REF -> $NEW_REF"
echo "  (library target: $SRC_SUBPATH)"
echo

removed="$(comm -23 "$api_old" "$api_new" || true)"
added="$(comm -13 "$api_old" "$api_new" || true)"

if [[ -n "$removed" ]]; then
  echo "REMOVED / RENAMED (potential BREAKING change):"
  echo "$removed" | sed 's/^/  - /'
  echo
fi

if [[ -n "$added" ]]; then
  echo "ADDED (additive):"
  echo "$added" | sed 's/^/  + /'
  echo
fi

if [[ -z "$removed" && -z "$added" ]]; then
  echo "No change to the public API surface."
fi

rm -f "$api_old" "$api_new"

if [[ -n "$removed" ]]; then
  echo "RESULT: breaking changes detected — bump at least a minor version and document a migration note." >&2
  exit 1
fi

echo "RESULT: additive-only (or no change)."
exit 0
