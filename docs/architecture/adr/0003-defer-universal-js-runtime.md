# ADR-0003 — Defer the universal JS/TS runtime (Lane B) until the Apple baseline is stable

**Status:** Accepted — 2026-05-15

## Context

[`AGENT_BOOTSTRAP_PLAN.md`](../../../AGENT_BOOTSTRAP_PLAN.md) calls for a two-lane product: Lane A (Apple-native, Swift) and Lane B (universal, TypeScript/JS browser runtime), unified by shared task definitions and benchmark cases. The plan rates Lane B as Phase 3 work, after Phase 1 (single-document MVP core) and Phase 2 (Apple-native flagship).

Current reality:

- Lane A's extraction core is functional but not yet "stable for external consumers" per [`MILESTONE_GATES.md`](../../../MILESTONE_GATES.md). Schema is still churning.
- No JS/TS consumer exists. The closest thing is `eval/` (Node) and `shared/tokenizer/parseText.js`, both internal tooling.
- The plan's own rule: *do not add infrastructure without a concrete consumer.*
- The plan's own risk register: *JS path underperforms badly — countermeasure: scope browser features realistically and maintain parity only on core jobs at first.*

## Decision

Lane B is on the backlog but is **not** scaffolded in this repo at this time. No `apps/web/`, no `packages/contracts/`, no TS toolchain, no parity eval, no shared TaskDefinition type system yet.

When Lane B is started — at the earliest after Phase 1 exit criteria are met (Apple baseline stable, schema churn slowed, regression gate repeatable) — a follow-up ADR will define the entry point, the parity-eval strategy, and the contract-sharing mechanism.

## Consequences

- **No empty TS / web directories** clutter the repo. The plan's `apps/web/`, `packages/contracts/`, `packages/eval/` (TS) trees stay deferred.
- **Shared contracts stay in their current location.** `shared/content-structure.schema.json` and `shared/tokenizer/` are the cross-runtime artifacts as of today. They are already consumed by Node-side `eval/` tooling and Swift-side `ScribeTokenizer`, so cross-language parity is already being exercised on a narrow surface.
- **Risk: Apple monoculture creep.** If Lane A's extraction logic depends on Apple-only frameworks (PDFKit, Vision, FoundationModels), porting becomes harder over time. Mitigation: when a non-Apple-specific extraction heuristic is added (e.g., footnote pattern matching, header detection), keep it expressible as a pure-data spec where reasonable, so a future TS port has less to re-derive.
- **No parity benchmark yet.** When Lane B begins, expect the first task to be reproducing a subset of the 11-book corpus runs and matching `eval/regression.js` outputs within a documented tolerance.

## Alternatives considered

1. **Scaffold empty TS/web dirs now to signal direction.** Rejected. Violates the plan's no-infrastructure-without-consumer rule. Empty scaffolding rots, gets touched out of habit, and creates the illusion of progress.

2. **Start Lane B in parallel with Phase 1.** Rejected. The plan explicitly orders Lane B as Phase 3 and warns about premature multi-runtime divergence. Lane B before contract stability multiplies the eventual reconciliation cost.

3. **Move existing JS-side eval/tokenizer into a future packages/ tree now.** Rejected. They have no second consumer; moving them only forces churn in their current consumer (`eval/`).

## Acceptance signals

- Apple baseline reaches "stable for external consumers" per `MILESTONE_GATES.md` exit criteria.
- A concrete Lane B use case is articulated (browser-based document upload, a JS SDK consumer, a web reader).
- A follow-up ADR defines Lane B's entry point.

## Revisit triggers

- A web product surface in the Velo / Pleroma ecosystem requires document intelligence.
- A third-party consumer requests a JS SDK.
- Phase 1 exit criteria from the bootstrap plan are met and Phase 2 work (Apple flagship) is meaningfully underway.
- Apple-only framework dependencies in the extraction core grow to the point where eventual portability becomes prohibitive — earlier ADR revisit warranted.
