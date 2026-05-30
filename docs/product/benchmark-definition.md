# Scribe — Benchmark Definition (v0)

This document codifies the **current** evaluation surface and the **gaps** that need to close before Scribe can claim a serious "evaluation-first development" posture per the bootstrap plan.

If you change extraction logic, you measure against this benchmark before merging. "Feels better" is not acceptable.

## Current benchmark: fidelity scoring on the corpus

Lives in [`../../eval/`](../../eval). Scores `predicted.json` (current Scribe output) against `native.json` (hand-annotated ground truth) for each book in [`../../corpus/`](../../corpus).

### The 7 fidelity dimensions

| Dimension | Measures | Implementation |
|---|---|---|
| `chapter_boundaries` | Chapter start/end alignment vs ground truth | `eval/score.js` |
| `titles` | Chapter title accuracy (fuzzy match) | `eval/score.js` |
| `footnotes` | Footnote detection and separation | `eval/score.js` |
| `headers` | Running header removal completeness | `eval/score.js` |
| `completeness` | Text coverage (no dropped content) | `eval/score.js` |
| `reading_order` | Correct sequential ordering | `eval/score.js` |
| `back_matter` | Bibliography/index/notes detection | `eval/score.js` |

### Corpus (11 books)

Each book in `corpus/{name}/` ships with:

- `book.json` — metadata (title, author, source)
- `native.json` — hand-annotated ground truth `contentStructure`
- `predicted.json` — most recent Scribe output
- `baseline.json` — locked fidelity scores from last stable run
- `fidelity-report.json` — detailed diff (what was missed/wrong)

Profile coverage:

| Book | Profile |
|---|---|
| `healing-dream` | Clean digital, academic — **primary test** |
| `janus-faces` | Scanned OCR, academic with heavy footnotes |
| `anatomy-melancholy` | Academic, heavy footnotes |
| `attention-paper` | Academic paper, two-column |
| `911-commission` | Government report, complex layout |
| `alice-wonderland` | Fiction, illustrated |
| `sherlock-holmes` | Fiction, clean digital |
| `prometheus-atlas` | Visual-heavy |
| `self-help-smiles` | General non-fiction |
| _(+ 2 more)_ | |

### Regression gate

`eval/regression.js` runs every book, compares against locked `baseline.json`, and fails if any dimension drops more than 2% (tunable). New baselines are explicit (committed), never silent.

**Policy**: changes that touch extraction logic require a regression run **before merge**. New baselines must be justified in the commit / PR body.

## Mapping to the bootstrap plan's benchmark categories

The bootstrap plan lists 6 minimum benchmark categories. Current coverage:

| Plan category | Current coverage | Gap |
|---|---|---|
| 1. Extraction accuracy (exact match, partial match, schema validity) | Partial — fidelity dimensions cover extraction; schema validity not enforced in CI | Add `ajv` validation pass to regression |
| 2. Question answering quality | None | No gold QA set yet — Phase 1 deliverable |
| 3. Summarization quality | None | `DocumentIntelligence.summarize` ships without an eval — see ADR-0002 acceptance gap |
| 4. Retrieval quality (recall@k, MRR/nDCG) | None | No retrieval layer yet |
| 5. Runtime quality (p50/p95 latency, peak memory, model load time) | None tracked in CI | Add `eval/perf.js` capturing wall time + peak RSS per book |
| 6. Robustness (long docs, malformed docs, scanned, adversarial) | Implicit via corpus mix | No targeted adversarial set; no "torture" book |

These gaps are tracked in [`../../BACKLOG.md`](../../BACKLOG.md) and are roughly in priority order: schema validation in regression → perf capture → QA gold set → robustness slices → intelligence-output evals.

## Benchmark policy

From the bootstrap plan, enforced here:

1. **Every shipped change compares against the current baseline.** Extraction changes → fidelity regression run. Intelligence changes → manual review until an intelligence benchmark exists.
2. **No model, prompt, chunking, or ranking change ships without evidence.** When the retrieval / chunking / reranking layers arrive, they ship with their own gold set and metric.
3. **Track quality and performance together.** As soon as `eval/perf.js` exists, a quality regression that costs >20% latency is treated as a regression regardless of the quality delta.
4. **No silent benchmark changes to make a candidate look better.** Baselines move via an explicit commit; new books enter the corpus via PR + ADR-if-needed.
5. **Holdout discipline.** Once an intelligence eval exists, hold out a slice that is not used during prompt/model iteration.

## Acceptance criteria (when can Scribe call itself "evaluation-gated"?)

- Schema validity check passes for every `predicted.json` in regression.
- Latency + peak memory captured per book and tracked over time.
- At least one of: QA gold set, summarization eval, retrieval eval — to cover the intelligence layer.
- Regression gate runs reliably from a single `npm` (or Make) command and emits a comparable report artifact.

Until all four are true, Scribe has **partial** evaluation coverage. Be honest about that in releases.
