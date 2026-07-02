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

1. **Schema churn has slowed** — no breaking `contentStructure` change for a full minor-release cycle (0.3.x → 0.4.0). Additive fields don't reset the clock.
2. **Regression runs are repeatable by a stranger** — fresh clone + `corpus/download.sh` + documented steps reproduces the gate on the publicly downloadable books (satisfied today for 9 of 10 books; janus-faces source remains private).
3. **One consumer contract exercised end-to-end at runtime** — not just a build: rsvp-reader's Capacitor bridge (or velo-macos import flow) returns schema-valid `contentStructure` from a real document in the running app, against the release candidate.
4. ✅ **Schema validation automated** — done 2026-07-02. `eval/regression.js` validates every `corpus/*/predicted.json` against `shared/content-structure.schema.json` (Ajv2020, draft 2020-12, + ajv-formats) before scoring; any violation fails the run with per-book errors. CI installs the eval deps (`npm ci` in `eval/`) ahead of the regression step.
5. **Public API diff reviewed at tag time** — no undocumented breaking change vs the prior tag (tooling queued in BACKLOG; manual review acceptable).

## Not Yet A Release Gate

- ~~EPUB cross-file chapter boundaries (quality gap, tracked in BACKLOG)~~ — done 2026-07-02: global paragraph stream + toc-anchor cuts; pride-prejudice overall 96.1% → 100.0%. Contract shape unchanged.
- Peak-memory reduction for large scans (1.7 GB RSS worst case, see `docs/benchmarks.md`) — matters for iOS positioning; gate it on the first consumer shipping large-scan import on iPhone.

## Immediate Next Decision

Whether 1.0 waits for the velo-macos end-to-end runtime smoke (currently blocked by that app's own in-flight work) or accepts rsvp-reader alone as the exercised consumer contract.
