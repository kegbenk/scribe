#!/usr/bin/env bash
#
# privacy-audit.sh — mechanically enforce docs/ops/privacy-principles.md on the
# deterministic core (swift/Sources/Scribe).
#
# Scribe's competitive contract is "your documents never leave the device." This
# script encodes the "Audit checklist (run before each tag)" from
# docs/ops/privacy-principles.md so it can run in CI and pre-tag, instead of being
# a manual grep. It exits non-zero on any violation.
#
# Usage:
#   tools/privacy-audit.sh
#
# Checks (mapped to privacy-principles.md):
#
#   1. Networking capability in the core (principle #1, "How this constrains
#      design", checklist line 1). The core MUST NOT reference any networking API.
#      These are violations ANYWHERE in swift/Sources/Scribe — including comments —
#      because a reference means the capability was reachable at some point:
#        import Network, URLSession, NSURLConnection, NWConnection,
#        NWPathMonitor, NWListener, CFSocket, CFStream
#
#   2. Remote URLs / fetch in code (checklist line 1). http://, https://, and
#      `fetch` are violations only OUTSIDE comments and doc-URL comments (an Apache
#      license or arXiv link in a doc comment is fine; a real request is not). We
#      strip `//` line/doc comments before matching.
#
#   3. No new external Package dependencies (checklist line 2). The published
#      manifest (root Package.swift) must declare zero package dependencies; the
#      dev manifest (swift/Package.swift) may only depend on swift-argument-parser
#      (CLI-only, never linked by library consumers).
#
# Limitation: this is a static grep, not a call-graph analysis. It catches the
# named APIs and URL literals; it cannot prove the absence of networking reached
# via, e.g., dynamic Objective-C runtime calls. Combined with "no external deps"
# and code review, it is a strong mechanical guard.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$REPO_ROOT/swift/Sources/Scribe"

fail=0
note() { printf '%s\n' "$*"; }
violation() { printf 'VIOLATION: %s\n' "$*" >&2; fail=1; }

note "Privacy audit: $CORE_DIR (per docs/ops/privacy-principles.md)"
note

# --- Check 1: networking APIs anywhere in the core -------------------------------
NET_SYMBOLS='import[[:space:]]+Network\b|URLSession|NSURLConnection|NWConnection|NWPathMonitor|NWListener|CFSocket|CFStream'
if hits="$(grep -rnE "$NET_SYMBOLS" "$CORE_DIR" 2>/dev/null)"; then
  violation "networking API referenced in the deterministic core:"
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
else
  note "OK: no networking APIs (URLSession/NSURLConnection/NWConnection/import Network/...) in core."
fi

# --- Check 2: remote URLs / fetch in non-comment code ----------------------------
# Strip `//...` (line and `///` doc comments) so doc-URL links don't false-positive.
url_hits=""
while IFS= read -r -d '' f; do
  # Strip `//` line/doc comments, but NOT the `//` inside a `://` URL scheme
  # (a `//` counts as a comment only when it isn't preceded by a colon).
  stripped="$(sed -E 's,([^:])//.*$,\1,; s,^//.*$,,' "$f")"
  if match="$(printf '%s\n' "$stripped" | grep -nE 'https?://|\bfetch\b' || true)"; then
    if [[ -n "$match" ]]; then
      url_hits+="$f:"$'\n'"$match"$'\n'
    fi
  fi
done < <(find "$CORE_DIR" -name '*.swift' -print0)

if [[ -n "$url_hits" ]]; then
  violation "remote URL or fetch in non-comment code:"
  printf '%s\n' "$url_hits" | sed 's/^/    /' >&2
else
  note "OK: no http(s):// or fetch in executable (non-comment) core code."
fi

# --- Check 3: no external package dependencies -----------------------------------
# Root (published) manifest: zero dependencies.
if grep -qE '^\s*dependencies:\s*\[\s*$' "$REPO_ROOT/Package.swift" && \
   grep -A3 -E '^\s*dependencies:\s*\[' "$REPO_ROOT/Package.swift" | grep -qE '\.package\('; then
  violation "root Package.swift (published to consumers) declares a package dependency; the library must have none."
else
  note "OK: published Package.swift declares no external package dependencies."
fi

# Dev manifest: only swift-argument-parser (CLI target) is allowed.
dev_deps="$(grep -oE '\.package\(url: "[^"]+"' "$REPO_ROOT/swift/Package.swift" | sed -E 's/.*"(.*)"/\1/' || true)"
while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  case "$dep" in
    *swift-argument-parser*) : ;; # CLI-only, never linked by library consumers
    *) violation "unexpected dependency in dev Package.swift: $dep" ;;
  esac
done <<< "$dev_deps"
if [[ "$fail" -eq 0 ]]; then
  note "OK: dev Package.swift dependencies limited to swift-argument-parser (CLI only)."
fi

note
if [[ "$fail" -ne 0 ]]; then
  note "PRIVACY AUDIT FAILED — see violations above."
  exit 1
fi
note "PRIVACY AUDIT PASSED."
exit 0
