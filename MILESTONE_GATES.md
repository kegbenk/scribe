# Scribe Milestone Gates

Use these gates to keep `scribe` moving without pretending the API and evaluation surfaces are already stable.

## Completed Milestone — stabilize the extraction contract (exited 2026-07-02)

All exit criteria met:

1. ✅ `contentStructure` schema changes are intentional and documented — ADR-0002 (intelligence optional), ADR-0004 (`level`), ADR-0005 (EPUB, same contract), `docs/runtime-contracts.md`.
2. ✅ CLI output matches the schema contract — spot-checked per release; ajv automation still queued in BACKLOG.
3. ✅ Regression/eval passes after extraction changes — now automated: CI runs the full corpus gate on every push/PR.
4. ✅ Consumer expectations written down — `CONSUMERS.md`.
5. ✅ Intelligence modules do not bypass baseline extraction — structural guarantee per ADR-0002 (`ScribeProcessor` runs no model code; `DocumentIntelligence` layers on top).

The "Immediate Next Decision" from this milestone was resolved by ADR-0002: document-intelligence additions are **optional enrichments**, not part of the default pipeline and not an experimental branch.

## Current Milestone

Reach stable-for-external-consumers (1.0) and announce.

## Exit Criteria For This Milestone

1. **Schema churn has slowed** — no breaking `contentStructure` change for a full minor-release cycle (0.3.x → 0.4.0). Additive fields don't reset the clock. **Clock started 2026-07-02 at the 0.4.0 tag:** 0.4.0 ships no breaking `contentStructure` change vs 0.3.0 (EPUB arrives through the same contract; the only metadata-shape change is the drop of the volatile `metadata.generatedAt` field from CLI output — additive/removal of a producer-private timestamp, coordinated in the release notes). The next breaking schema change, if any, must not land before the 0.4.x cycle completes.
2. **Regression runs are repeatable by a stranger** — fresh clone + `corpus/download.sh` + documented steps reproduces the gate on the publicly downloadable books (satisfied today for 9 of 10 books; janus-faces source remains private).
3. ✅ **One consumer contract exercised end-to-end at runtime** — satisfied 2026-07-02, two ways:
   - **velo-macos (full literal pass):** the running app imported real documents through its actual import flow (`DocumentImportService` → `DocumentIntelligence.extract` → reader render) and the captured `contentStructure` the app received validated against `shared/content-structure.schema.json` (gate-#4 ajv) for all three: `attention-paper` PDF (10 chapters, 4,711 words), `pride-prejudice` EPUB (64 chapters, 130,083 words), and a third-party EPUB (283 chapters, 181,151 words). Verified against Scribe main at the 0.4.0 revision, in the app UI (chapters/TOC rendered).
   - **rsvp-reader (full literal pass, 2026-07-03):** the genuine Capacitor bridge call (`window.Capacitor.Plugins.VeloPDFProcessor.extractContent`) exercised inside the running app in the iOS simulator against Scribe 0.4.0 — PDF (attention-paper: 10 chapters, nested outline levels) and EPUB (128 chapters), both schema-valid. The former simulator blocker was FolioReaderKit's pinned Realm 3.13.1 (device-only static core); fixed by an install-phase strip for the sim-only build config (rsvp-reader branch `fix/realm-simulator-embed-install`, awaiting review). Note: rsvp-reader's lockfile still resolves Scribe 0.1.3 — bumping to 0.4.0 verified working and is the top consumer follow-up.
4. ✅ **Schema validation automated** — done 2026-07-02. `eval/regression.js` validates every `corpus/*/predicted.json` against `shared/content-structure.schema.json` (Ajv2020, draft 2020-12, + ajv-formats) before scoring; any violation fails the run with per-book errors. CI installs the eval deps (`npm ci` in `eval/`) ahead of the regression step.
5. ✅ **Public API diff reviewed at tag time** — tooling now exists (`tools/api-diff.sh`, BACKLOG item closed 2026-07-02) and was **exercised for the 0.4.0 tag**: `tools/api-diff.sh 0.3.0 HEAD` reports no change to the public library surface (EPUB added only `internal` symbols). No undocumented breaking change vs the prior tag.

## Not Yet A Release Gate

- ~~EPUB cross-file chapter boundaries (quality gap, tracked in BACKLOG)~~ — done 2026-07-02: global paragraph stream + toc-anchor cuts; pride-prejudice overall 96.1% → 100.0%. Contract shape unchanged.
- Peak-memory reduction for large scans (1.7 GB RSS worst case, see `docs/benchmarks.md`) — matters for iOS positioning; gate it on the first consumer shipping large-scan import on iPhone.

## Immediate Next Decision

Whether 1.0 waits for the velo-macos end-to-end runtime smoke (currently blocked by that app's own in-flight work) or accepts rsvp-reader alone as the exercised consumer contract.
