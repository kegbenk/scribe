# ADR-0001 — ADR Template

**Status:** Accepted (template — copy to a new file when writing a real ADR)

## Context

What is the situation that requires a decision? What forces are at play (technical, organizational, consumer-facing, performance, privacy)? Cite specific files, consumers, or benchmark dimensions where relevant.

## Decision

The decision in one paragraph. Active voice. Specific. "We will X because Y."

## Consequences

- What changes for the codebase
- What changes for consumers ([`CONSUMERS.md`](../../../CONSUMERS.md))
- What changes for the benchmark / eval surface
- What new work this creates
- What this forecloses

## Alternatives considered

1. **Alternative A** — what it is, why rejected
2. **Alternative B** — what it is, why rejected

## Acceptance signals

How will we know this decision was right or wrong? Tie to benchmark dimensions, consumer behavior, or measurable performance budgets where possible. "Feels better" is not acceptable per the bootstrap plan.

## Revisit triggers

Conditions that should re-open this decision (e.g., "if a JS consumer is added," "if extraction quality drops below 0.92 on the locked baseline," "if a new file type is introduced").

---

### Filename convention

`docs/architecture/adr/NNNN-short-kebab-title.md` — zero-padded sequential, no gaps.

### Status values

`Proposed` → `Accepted` | `Rejected` → `Superseded by ADR-NNNN` | `Deprecated`

### When to write an ADR

Per the bootstrap plan's ADR triggers:

- runtime model format changes
- chunking strategy changes materially
- retrieval stack changes materially
- Apple and JS contract divergence is proposed
- a new file type is added that impacts architecture
- cloud features are introduced for any core path
- a new local database/index strategy is chosen

Also write one when resolving an explicit open question from `MILESTONE_GATES.md` or a `[?]` in the system overview.
