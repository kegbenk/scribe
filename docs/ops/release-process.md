# Scribe — Release Process

Scribe is consumed by two real apps. Releases must not break them, and the process below makes that explicit.

## Versioning

Semantic versioning. Currently `0.x` — the API and schema are still allowed to break between minor versions, but every break is documented and consumers are updated in the same window.

| Version range | Means |
|---|---|
| `0.x.y` | Unstable. Minor (`x`) bumps may break consumers. Patch (`y`) bumps are fixes only. |
| `1.0.0` | Cut only when [`MILESTONE_GATES.md`](../../MILESTONE_GATES.md) exit criteria are met: schema churn slowed, regression runs repeatable, consumer contracts exercised end-to-end. |
| `1.x.y` | Stable. Breaking changes require a major bump and a documented migration path. |

## Pre-release checklist

Before tagging any release:

1. **Regression run is green.**
   `cd eval && node regression.js` — all books within 2% of locked baseline on all 7 fidelity dimensions. If a baseline moved, the move is justified in the commit message and reflected in the new tag's release notes.

2. **Schema validity.**
   Every `predicted.json` in the corpus validates against `shared/content-structure.schema.json`. (Until this check is automated, do a spot-check on at least `healing-dream`, `janus-faces`, and one fiction book.)

3. **Build and smoke-test both consumers locally.**
   - `velo-macos` builds against this repo's local SPM path and the import flow runs end-to-end against a sample PDF.
   - `rsvp-reader` builds (iOS target) and the Capacitor bridge call returns valid `contentStructure` JSON.
   See [`../../CONSUMERS.md`](../../CONSUMERS.md) for the exact API surfaces each consumer touches.

4. **Public API diff.**
   Compare public API of `swift/Sources/Scribe/` vs the previous tag. If anything in `CONSUMERS.md` changed signature, behavior, or return-shape, the version bump must be at least minor and the change must appear in the release notes with a migration note.

5. **Privacy audit passes.**
   `bash tools/privacy-audit.sh` exits 0 — the deterministic core
   (`swift/Sources/Scribe`) references no networking APIs and pulls no external
   package dependencies, per [`privacy-principles.md`](privacy-principles.md). Also
   runs first in CI, so a clean CI run already covers this; re-run locally before
   tagging as a belt-and-suspenders check.

6. **CHANGELOG.** _(deferred until first 1.0 release; until then, use git log + release notes on the tag.)_

## Tagging

```bash
git tag -a v0.x.y -m "release notes"
git push origin v0.x.y
```

Tags are immutable. If a tagged release turns out broken, cut a new patch — do not retag.

## Breaking changes

A breaking change is any of:

- Removing or renaming an API listed in `CONSUMERS.md`
- Changing the return type or key names of `contentStructure`
- Changing tokenization (`ScribeTokenizer.parseText()`) in a way that changes word boundaries or word indices
- Changing extraction output in a way that meaningfully shifts the fidelity baseline downward on the corpus

Process for a breaking change:

1. Write or update an ADR if architectural ([`../architecture/adr/0001-adr-template.md`](../architecture/adr/0001-adr-template.md)).
2. Land the change in both consumer repos on a branch.
3. Cut the Scribe release first, then the consumer releases. Note the required Scribe version in the consumer's release.

## Schema changes

`shared/content-structure.schema.json` is the cross-runtime contract. Changes:

- **Additive optional field**: minor bump. Consumers ignore it safely.
- **Additive required field**: breaking. Major bump (or minor while in `0.x`). Coordinate with consumers.
- **Removing or renaming a field**: breaking.
- **Loosening a type** (e.g., string → string|null): minor, but flag in release notes.
- **Tightening a type**: breaking.

The `intelligence` block remains optional per [ADR-0002](../architecture/adr/0002-document-intelligence-as-optional-enrichment.md).

## "Not yet a release gate"

Per `MILESTONE_GATES.md`, the repo is not yet treated as stable-for-external-consumers. Releases during this period should:

- Note in the tag message that this is a 0.x pre-stability release
- Avoid simultaneous schema + extraction changes whenever possible
- Update `CONSUMERS.md` when API surfaces change
- Be tied to a consumer-side update PR, even if just bumping the version

## Eventual automation (deferred)

- CI regression run on every PR touching `swift/Sources/Scribe/` or the schema
- Consumer build smoke-tests in CI (would require checking out velo-macos / rsvp-reader)
- Automated changelog from commits

None of these block 0.x releases. They are tracked in [`../../BACKLOG.md`](../../BACKLOG.md).
