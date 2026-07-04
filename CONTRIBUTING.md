# Contributing to Scribe

Thanks for your interest. Scribe is a small, deliberately-scoped library with a
strict quality gate — this page tells you how to work inside it.

## Ground rules

- **Zero third-party dependencies in the library.** The published package uses
  Apple frameworks only. PRs adding a dependency to the root `Package.swift`
  will be declined (dev-only tooling in `eval/` is fine).
- **No network I/O in extraction.** `tools/privacy-audit.sh` enforces this in
  CI; see `docs/ops/privacy-principles.md`. "Documents never leave the device"
  is a product contract, not a preference.
- **No eval theater.** Ground truth (`corpus/*/native.json`) is never edited to
  match code output. Baselines move only with explicit justification. See
  ADR-0004.
- **Architecture changes need an ADR** (`docs/architecture/adr/`). Small fixes
  don't.

## Dev setup

```bash
git clone https://github.com/kegbenk/scribe.git && cd scribe
swift build --package-path swift          # library + scribe-cli
swift test  --package-path swift          # unit tests
(cd eval && npm ci)                       # eval harness deps (ajv)
bash corpus/download.sh                   # public-domain corpus sources
node eval/regenerate.js                   # re-extract corpus books
node eval/regression.js                   # schema validation + fidelity gate
```

Two manifests exist on purpose: the root `Package.swift` is what consumers
resolve (library only); `swift/Package.swift` is the dev manifest with the CLI
and tests. Keep shared targets in sync.

## Before you open a PR

1. `swift test --package-path swift` — all tests green.
2. `node eval/regression.js` — no fidelity dimension drops more than 2% below
   its locked baseline; every `predicted.json` schema-valid.
3. `tools/privacy-audit.sh` — passes.
4. `tools/api-diff.sh <base> HEAD` — know whether your change touches the
   public API, and say so in the PR. Breaking changes need coordination
   (see `docs/ops/release-process.md`).
5. If extraction output changed: regenerate the corpus
   (`node eval/regenerate.js`) and commit the resulting `predicted.json`
   changes with your PR. Scanned-book output drifts slightly between runs
   (Vision OCR is nondeterministic) — don't commit churn on books your change
   doesn't affect.

## What makes a good contribution

Fidelity improvements measured against the corpus, new corpus books with
honestly-derived ground truth, EPUB/PDF edge cases with a failing test first,
and performance work with before/after numbers (`node eval/perf.js`). If
you're unsure whether something fits, open an issue before writing code.

## Conduct

Be kind. The [Code of Conduct](CODE_OF_CONDUCT.md) applies to all project
spaces.
