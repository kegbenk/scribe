# ADR-0004 — Expose nested PDF outline hierarchy via a `level` field on TOC and outline items

**Status:** Accepted — 2026-05-30

## Context

The previous chapter-detection behavior in `ScribeProcessor` deduped PDF outline items per page: when multiple outline entries pointed to the same page (typical for top-level chapters and their nested subsections), only the first (top-level) one was kept. The result was a flat list of "chapter" entries with no hierarchy information.

The in-flight DocumentIntelligence work changes this. Specifically:

- `ChapterDetection.swift` removes the per-page dedup. All outline items are emitted in DFS order.
- A new `level: Int` field is added to `OutlineItem` (internal) and `TOCEntry` (public, in `ContentStructure` and the JSON schema). Level 0 = top-level, 1 = first nested child, etc.
- The depth is computed during outline traversal in `collectOutlineItems`.

This is a deliberate change. It exposes the document's natural hierarchy to consumers that can render nested TOCs.

It also has measured impact on the existing fidelity benchmark. Running current code against `corpus/attention-paper`:

| Dimension | Old baseline | Current code | Δ |
|---|---|---|---|
| chapter_titles | 100.0% | 41.1% | −58.9% |
| body_text_completeness | 99.9% | 96.8% | −3.1% |
| OVERALL | 99.8% | 91.7% | −8.1% |

The "regression" is real but largely artifactual: `native.json` for each book in the corpus was hand-annotated against the **old** flat-outline contract. Where the old code produced `Introduction`, `Encoder and Decoder Stacks`, `Training`, the new code produces `Model Architecture`, `Attention`, `Multi-Head Attention` — both are correct outline items, but at different depths.

## Decision

The new contract is: **`TOCEntry` always carries a `level: Int` field. Consumers receive the document's full outline hierarchy, not a deduped flat list. Top-level items have `level == 0`; nested items have `level >= 1`.**

Operationally:

1. `ScribeProcessor`'s chapter detection emits every outline item produced by `collectOutlineItems`, in DFS order, each with its computed depth.
2. `OutlineItem` (internal) carries `(title, pageIndex, level)`.
3. `ContentStructure.TOCEntry` carries `(title, wordIndex, chapterIndex, level)`. The `level` field is required-in-Swift but **decodes-with-default-0** when reading pre-existing JSON (custom `init(from:)` falls back to 0 via `decodeIfPresent`). This protects velo-macos against decoding any cached JSON that pre-dates this ADR.
4. The JSON schema lists `level` as an optional integer on `TOCEntry`. Producers that pre-date this ADR (the only one in the wild: Scribe 0.1.x) may omit it; consumers tolerate absence.
5. Consumers can render flat or nested at their discretion. There is no library-side flag to revert to the old dedup behavior.

## Consequences

**For consumers:**

- **rsvp-reader** (iOS, JS via Capacitor) — its current TOC UI was designed for the flat-chapter contract. The new `level` field is additive in JSON, but the new emit-all-nested behavior means rsvp-reader will receive more entries per document. Before any Scribe release that includes this change, rsvp-reader's outline rendering must be reviewed and either (a) flatten `level > 0` entries client-side, (b) render the hierarchy, or (c) document that nested entries display alongside top-level ones.
- **velo-macos** (macOS, Swift via local SPM) — same concern. The `DocumentIntelligence` facade re-emits whatever `ScribeProcessor` produces. Its TOC view needs the same review.

This work MUST happen before tagging a Scribe release that carries this change. Tracked in `BACKLOG.md` under consumer-coordination.

**For the benchmark / corpus:**

- The corpus's hand-annotated `native.json` files reflect the **old** flat-outline contract. They are now stale ground truth for the new contract.
- Until a re-annotation pass runs, the fidelity gate will under-report extraction quality on books whose PDFs have nested outlines (most academic books).
- For `attention-paper` specifically: `baseline.json` is updated to the new code's score (91.7%) so the regression gate's delta-against-baseline check stays useful for future changes. `native.json` is **not** updated here — that would conflate "what we measure against" with "what the code produces," which is exactly the evaluation-theater risk the bootstrap plan warns about. Re-annotation must be a deliberate human pass.
- For the other 7 corpus books: their source PDFs are not in the repo (separate problem tracked under "corpus PDF gap"). `predicted.json` and `baseline.json` for those books will be updated once PDFs are restored and current code can be run against them.

**For the schema and contracts:**

- `shared/content-structure.schema.json` already declares `TOCEntry` without `level` in its `required` array. No schema change needed; the new field is additive-optional in JSON terms.
- `docs/runtime-contracts.md` is updated to note that `level` is now part of the contract on output.

**For Swift API stability:**

- `ContentStructure.TOCEntry`'s memberwise initializer signature changed: it now takes `level: Int = 0` as a defaulted last parameter. Consumers that construct `TOCEntry` values themselves (none currently, per `CONSUMERS.md`) are source-compatible because `level` has a default.
- `TOCEntry.init(from decoder:)` is custom and tolerates missing `level`. Cached JSON decodes without error.

## Alternatives considered

1. **Restore the per-page dedup, drop `level`.** Lowest blast radius, keeps consumer UI unchanged, lets us focus the current commit cycle purely on the intelligence layer. Rejected because Benjamin chose to lock in the nested behavior; richer TOC is a genuine product win for reader UX.

2. **Add a `flatten: Bool` parameter to extraction.** Keep both behaviors selectable. Rejected as premature configurability — neither consumer needs the choice right now, and the lean-scaffolding principle says: don't add a parameter until a real caller demands it. Future ADR can revisit if a consumer ever needs the old behavior.

3. **Re-annotate `native.json` automatically from current code's output.** Rejected — this is exactly the evaluation-theater pattern the bootstrap plan warns against ("no silent benchmark changes to make candidates look better"). Ground truth must be human-authored or human-reviewed.

## Acceptance signals

- **Confirmed 2026-05-30:** Both consumer apps already render `level` correctly. `velo-macos` (`VeloReaderView.swift:281`, `DocumentReaderView.swift:120`) indents its TOC menu by `String(repeating: "    ", count: chapter.level)`; its `ReadingEngine.chapters` is typed `[(title, text, level)]` and `DocumentImportService.buildContentDict` emits `chapter.level` into the JSON passed to its UI. `rsvp-reader` (`TOCPanel.svelte:86`) sets `class="toc-item level-{item.level}"` with CSS indentation rules for levels 1–6. The Scribe change is closing a gap the consumers already opened. velo-macos was the originating motivator.
- `corpus/attention-paper/predicted.json` and `baseline.json` reflect current code; `native.json` is updated only after a deliberate re-annotation pass.
- New regressions detected on the locked attention-paper baseline (91.7%) are treated as real regressions, not artifacts.
- A re-annotation pass for the full corpus is scheduled and tracked in BACKLOG.md.

## Revisit triggers

- A consumer needs deterministic flat output and cannot tolerate nested entries. Revisit alternative #2 (flatten flag).
- The re-annotation pass reveals systematic issues with the new outline emission (e.g., level-0 items being incorrectly suppressed). Revisit the DFS traversal logic itself.
- A new file type (EPUB, HTML) is added where "outline" has different semantics. Cross-format contract harmonization may be needed.
