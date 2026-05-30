# Scribe — Backlog

Source-of-truth for prioritized work, seeded from [`AGENT_BOOTSTRAP_PLAN.md`](AGENT_BOOTSTRAP_PLAN.md) but ordered against the current milestone in [`MILESTONE_GATES.md`](MILESTONE_GATES.md).

Items here are not a contract to ship. They're the candidate queue. Anything moved into active work should be tied to a benchmark dimension, a consumer need, or a documented gap.

---

## Now (current milestone: stabilize extraction + integrate intelligence)

Closes the exit criteria in `MILESTONE_GATES.md`.

- [x] **Diagnose current uncommitted state** — done 2026-05-30. Build green; corpus regression trivially passes because predicted.json is stale (only 1 of 8 books has its source PDF in repo).
- [x] **Phase A: platform safety pass** — done 2026-05-30. Reverted Package.swift to iOS 15 / macOS 12 + swift-tools 5.9; added `@available(iOS 26.0, macOS 26.0, *)` on DocumentIntelligence, SemanticAnalyzer, StructuralAnalyzer, @Generable types, and Analyze CLI subcommand; gated CLI's `--entities` flag with `if #available`. `TOCEntry` now decodes old JSON (defaults `level=0`).
- [x] **Consumer-coordination pass for nested-outline contract** ([ADR-0004](docs/architecture/adr/0004-nested-outline-and-level-field.md)) — verified 2026-05-30 at the source level. Both consumers were already designed for `level`-based indented TOCs; the Scribe change is catching up. velo-macos: builds clean and uses `chapter.level` in `VeloReaderView` + `DocumentReaderView` to indent TOC menus. rsvp-reader: `TOCPanel.svelte` renders `class="toc-item level-{item.level}"` with CSS for levels 1–6. Still: runtime smoke-test both apps after tagging (Task #6).
- [x] **Corpus source-PDF config and regeneration tooling** — done 2026-05-30. `corpus/sources.json` (gitignored) maps book slugs to PDF paths; `corpus/sources.example.json` is the template; `eval/regenerate.js` reads it and runs scribe-cli per book, skipping missing sources with clear warnings. `npm run regenerate` and `--book <slug>` / `--lock` flags supported. attention-paper validated end-to-end through the new flow.
- [ ] **Locate and configure source PDFs for the remaining 7 books** — `911-commission`, `alice-wonderland`, `anatomy-melancholy`, `healing-dream`, `janus-faces`, `prometheus-atlas`, `self-help-smiles`, `sherlock-holmes`. Find them on disk (external drive per disk-space memory) and add entries to `corpus/sources.json`. Then `node eval/regenerate.js --lock` to refresh predicted.json + baseline.json. Until this is done, the regression gate is partial for 7 of 8 books.
- [ ] **Make `predicted.json` output deterministic** — `ScribeCLI.buildContentStructure` emits a `generatedAt` ISO8601 timestamp in `metadata`, so every `regenerate` produces a different file even on identical input. Either drop the timestamp from the predicted output, or move it to a sidecar so the scored artifact stays diffable.
- [ ] **Re-baseline attention-paper** — `predicted.json` and `baseline.json` updated to current code's output. `native.json` LEFT ALONE pending corpus re-annotation pass.
- [ ] **Corpus re-annotation pass** — `native.json` files were hand-annotated against the OLD flat-outline contract. They are now stale ground truth for the new nested-outline contract (per ADR-0004). A deliberate human-authored re-annotation pass is required before the fidelity gate becomes trustworthy again on books with nested outlines. **Do NOT auto-regenerate native.json from current code's output** — that's evaluation theater.
- [ ] **Land staged commits** — once consumer-coordination is done and corpus is back, commit the work in coherent units: (1) docs + ADRs (additive), (2) Package.swift safety + @available gates, (3) intelligence modules + schema additions, (4) extraction-core changes including ChapterDetection + level field, (5) CLI additions, (6) corpus updates.
- [ ] **Add `ajv` schema validation to `eval/regression.js`** so every `predicted.json` is validated against `shared/content-structure.schema.json` per run. Closes the schema-validity gap from `docs/product/benchmark-definition.md`.
- [ ] **Decide structural-analysis (Vision RecognizeDocumentsRequest, iOS 26+) status** — is it included in default `DocumentIntelligence.process()` when available, or invoked separately? Possibly an ADR.
- [ ] **Document `DocumentIntelligence` public API in README.md** — README currently only covers `ScribeProcessor`. velo-macos consumers need a discoverable surface.
- [ ] **Smoke-test cycle**: build `velo-macos` and `rsvp-reader` against the post-commit Scribe and confirm both work end-to-end.

## Next (Phase 1 completion per bootstrap plan)

The plan's Phase 1 ("single-document MVP core"). Most of extraction is done; what's missing is retrieval, citation, and intelligence eval.

- [ ] **Capture latency + peak memory per book** in regression runs (`eval/perf.js`). Wire into the regression report.
- [ ] **Define citation-span format** — a typed object identifying `(chapter_index, start_word_index, end_word_index)` and serializable to the schema. Needed before answer-with-evidence is meaningful.
- [ ] **Add an answer-with-evidence structured output** (schema-validated). Initial implementation can be `DocumentIntelligence.ask(_:context:)` returning `{ answer, citations[], confidence }` — the public `ask` method exists, the structured output doesn't.
- [ ] **Build a chunking strategy** with stable IDs across re-runs. Chunks should reference word indices (same tokenizer as everywhere else).
- [ ] **Lexical retrieval baseline** (BM25 or similar) over chunks. No embeddings yet — keep deterministic first.
- [ ] **Build a 50–100-case QA gold set** drawn from existing corpus books. Hand-authored, with citation spans. Lives under `corpus/qa-gold/` or similar.
- [ ] **Summarization eval** — at minimum a factual-consistency check on a small slice of the corpus. Needed to retire the "intelligence ships without an eval" gap in ADR-0002.

## Later (Phase 2+: Apple flagship, Phase 3+: universal runtime, Phase 4: improvement loop)

- [ ] **Apple-native flagship app shell** — lives in `velo-macos` and/or a new repo, not in `scribe/`. Tracks Phase 2.
- [ ] **Universal JS runtime (Lane B)** — covered by [ADR-0003](docs/architecture/adr/0003-defer-universal-js-runtime.md). Revisit when the trigger conditions are met.
- [ ] **Candidate-proposal spec + experiment runner** — Phase 4 of the plan. Lets agents propose prompt / chunking / reranker changes that run against the benchmark suite before merging.
- [ ] **Promotion gate** — formal rules for when a candidate becomes a release.
- [ ] **Multi-document collections + cross-doc retrieval** — Phase 5.
- [ ] **`ModelArtifactManifest`** — when a compact task-specific model first ships with Scribe.

## Ops / hygiene

- [ ] **CHANGELOG.md** at 1.0 cut.
- [ ] **CI for regression run** on PRs touching `swift/Sources/Scribe/` or `shared/`.
- [ ] **CI smoke-test for consumers** (`velo-macos`, `rsvp-reader`).
- [ ] **Privacy audit script** (`grep` checks per `docs/ops/privacy-principles.md`'s audit checklist) wired into pre-tag.
- [ ] **Public API diff tool** to flag breaking changes in `swift/Sources/Scribe/` against the last tag.

## Risk register (from bootstrap plan, watched here)

| Risk | Watch for | Mitigation |
|---|---|---|
| Agentic overreach | New folders / abstractions without a consumer | This backlog rejects them; ADR-required for new architecture |
| Vendor lock-in (Apple-only) | Extraction logic that can only be expressed via PDFKit/Vision | When a heuristic could be expressed as a pure-data spec, prefer that form |
| JS path underperforms | When Lane B starts, parity gaps compound silently | Parity eval before declaring Lane B usable |
| Evaluation theater | Baselines drifting without commit justification | Baseline moves require explicit commit + release-note line |
| Parsing dominates quality | Quality gaps blamed on model when extraction is wrong | Fidelity gate runs before intelligence-layer quality is judged |
| Performance death by model size | Latency / memory regressions snuck in via intelligence layer | `eval/perf.js` (Now bucket) closes this gap |

---

## How to use this file

- **Pick from "Now" first.** If you're picking from "Next" or "Later," justify it in the PR or ADR.
- **Move items in/out** rather than letting the list grow indefinitely. Stale items are noise.
- **An item moves to "active"** when there's an open branch, PR, or ADR draft for it. Drop a link.
- **A completed item moves to a release note**, not a "done" section in this file.
