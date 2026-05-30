# AGENT_BOOTSTRAP_PLAN.md

## Purpose

This file is the root-level execution plan for the **Scribe** rebuild/adaptation effort.
It is written for an orchestration agent that needs to coordinate architecture, implementation,
experimentation, evaluation, and release planning.

The product goal is to build a **privacy-first, on-device document intelligence system** that:

1. Delivers strong local inference quality on Apple devices.
2. Maintains a portable cross-platform path that can run in browser / JavaScript environments.
3. Improves through a controlled evaluation loop rather than uncontrolled self-modification.
4. Separates **product inference** from **training / optimization / experimentation**.

This plan is intentionally execution-oriented. Treat it as the source of truth unless superseded by a later architecture decision record.

---

## Core Product Thesis

Scribe should be built as a **two-lane product sharing one evaluation system**:

- **Lane A: Apple-native runtime**
  - Best UX and best performance on Apple hardware.
  - Uses Swift-native APIs for orchestration and local intelligence features.
  - Ships compact task-specific models for core product differentiation.

- **Lane B: Universal runtime**
  - Runs in browser and other environments using JavaScript / TypeScript.
  - Provides broader device reach, fast testing, and cross-platform viability.
  - Shares task definitions, benchmarks, and model contracts with Lane A.

The moat is **not** a general-purpose model alone.
The moat is the combination of:

- domain-specific evaluation data
- robust benchmarks
- controlled model promotion
- tuned retrieval / ranking / extraction behavior
- private, low-latency local UX

---

## Non-Negotiable System Principles

1. **No uncontrolled self-rewriting in production.**
   Agents may propose improvements, but all changes must pass evaluation gates.

2. **Inference and training are separate systems.**
   Local product runtime performs inference only. Optimization happens offline or in controlled research pipelines.

3. **Deterministic core where possible.**
   Prefer deterministic retrieval, ranking, parsing, and structured extraction stages before asking a language model to improvise.

4. **Portable contracts, not portable everything.**
   Do not force one implementation language everywhere. Share task schemas, eval formats, and model interfaces instead.

5. **Every change must be measurable.**
   No component should be added without clear success metrics.

6. **Privacy-first by default.**
   User documents should stay on device unless explicitly opted into remote processing.

7. **Battery, memory, and latency matter as much as quality.**
   This is an on-device product. Model quality alone is not enough.

---

## High-Level Product Scope

### Primary capabilities

- ingest local documents
- normalize and parse documents
- chunk and index content
- retrieve relevant spans
- extract structured information
- summarize content
- answer questions over documents
- rank passages / sections / citations
- support offline local operation
- improve quality via benchmarked releases

### Likely v1 user jobs

- “Find the important parts of this document.”
- “Answer questions from this document with evidence.”
- “Extract structured fields from this document.”
- “Summarize this document in different styles.”
- “Search across one or more local files privately.”

### Explicitly out of scope for the first build wave

- autonomous production model self-training on user devices
- continuous code rewriting by agents without review
- large-scale cloud dependence for baseline inference
- broad multi-agent complexity before a single-agent orchestrator works
- premature support for every possible file type

---

## Operating Model For The Orchestration Agent

The orchestration agent should behave like a **technical program manager + staff engineer**.
It must not jump straight into coding everything at once.

Its responsibilities are:

1. break the project into streams
2. maintain dependency order
3. enforce evaluation-first development
4. assign work to specialized sub-agents when available
5. reject speculative work that is not tied to user value or benchmarks
6. maintain a backlog, execution log, and architecture decision records

### Required agent behaviors

- always check this file before planning work
- produce short written plans before major changes
- create ADRs for significant architecture choices
- update task status as work progresses
- run tests and evals before marking work complete
- prefer the smallest viable implementation that preserves extensibility

### Forbidden agent behaviors

- inventing product requirements not grounded in this file
- adding infrastructure without a concrete consumer
- replacing deterministic pipelines with pure prompting unless proven better
- shipping model or prompt changes without benchmark comparison
- creating duplicate runtimes with diverging task definitions

---

## System Architecture Overview

```text
+-------------------------+
|      User Documents     |
+-----------+-------------+
            |
            v
+-------------------------+
|   Ingestion / Parsing   |
| PDF / text / html / md  |
+-----------+-------------+
            |
            v
+-------------------------+
| Normalization / Chunking|
| metadata / sections     |
+-----------+-------------+
            |
            v
+-------------------------+
|   Local Index / Store   |
| embeddings / lexical    |
+-----+-------------+-----+
      |             |
      |             v
      |   +----------------------+
      |   | Language Orchestration|
      |   | summarize / extract   |
      |   | QA / tools / routing  |
      |   +----------+-----------+
      |              |
      v              v
+----------------+  +-------------------+
| Retrieval Core |  | Task-Specific ML  |
| rank / cite    |  | scoring / rerank   |
+--------+-------+  +---------+---------+
         |                    |
         +---------+----------+
                   |
                   v
         +-----------------------+
         | User-Facing Responses |
         | answer / evidence / UI|
         +-----------------------+

Separate research system:

+---------------------------+
|   Offline Evaluation Lab  |
| datasets / benchmarks     |
| candidate models/prompts  |
| agent-generated proposals |
+-------------+-------------+
              |
              v
+---------------------------+
|  Promotion / Release Gate |
| quality / latency / mem   |
+-------------+-------------+
              |
              v
+---------------------------+
| Runtime Model Artifacts   |
| CoreML / ONNX / configs   |
+---------------------------+
```

---

## Recommended Tech Strategy

### Runtime languages

- **Swift** for Apple-native app and local orchestration on Apple platforms.
- **TypeScript** for browser / cross-platform runtime.
- **Python** for research, evaluation, training, and tooling.
- **Optional Rust** only for proven performance-critical core libraries.

### Runtime model strategy

- compact task-specific local models for ranking / scoring / extraction where needed
- language model orchestration for flexible structured generation and QA
- portable model artifacts where possible
- avoid depending on a single vendor-specific capability for the entire product

### Shared cross-runtime contracts

Define these once and keep them aligned across Swift / TS / Python:

- `TaskDefinition`
- `DocumentSchema`
- `ChunkSchema`
- `RetrievalResult`
- `CitationSpan`
- `ExtractionSchema`
- `EvalCase`
- `EvalResult`
- `ModelArtifactManifest`

---

## Suggested Repository Structure

```text
scribe/
  AGENT_BOOTSTRAP_PLAN.md
  README.md
  docs/
    architecture/
      adr-0001-template.md
      system-overview.md
      runtime-contracts.md
    product/
      prd.md
      benchmark-definition.md
    ops/
      release-process.md
      privacy-principles.md
  apps/
    apple/
      ScribeApp/
    web/
      scribe-web/
  packages/
    contracts/
      task-definitions/
      schemas/
    core/
      ingestion/
      parsing/
      chunking/
      retrieval/
      ranking/
      citations/
    eval/
      harness/
      datasets/
      metrics/
    ui/
      shared-components/
  research/
    notebooks/
    experiments/
    model-training/
    prompt-lab/
  tooling/
    scripts/
    dataset-builders/
    export/
  tests/
    unit/
    integration/
    eval/
  data/
    sample-docs/
    golden-sets/
    synthetic/
```

---

## Workstreams

The orchestration agent should manage the project through these workstreams.

### Stream 1: Product definition and benchmark design
Goal: define what “good” means before large implementation work.

Deliverables:
- PRD
- benchmark spec
- task taxonomy
- success metrics
- latency and memory budgets

### Stream 2: Shared contracts and schemas
Goal: prevent runtime divergence.

Deliverables:
- JSON schemas or equivalent type contracts
- versioned task definitions
- artifact manifest format
- citation format

### Stream 3: Ingestion and document processing
Goal: get reliable local document understanding.

Deliverables:
- parsers
- normalization pipeline
- chunking strategy
- metadata extraction
- file-type support matrix

### Stream 4: Retrieval and evidence system
Goal: make outputs traceable and useful.

Deliverables:
- local indexing
- retrieval pipeline
- ranking / reranking
- citation spans
- evidence packaging

### Stream 5: Apple-native runtime
Goal: build the flagship local experience.

Deliverables:
- document import
- local query flow
- summarization / extraction flow
- citations in UI
- model artifact loading

### Stream 6: Universal JS runtime
Goal: preserve portability and broad availability.

Deliverables:
- browser ingestion path
- browser inference path
- shared task execution
- eval parity checks against Apple path

### Stream 7: Evaluation harness and promotion gate
Goal: stop random regressions.

Deliverables:
- fixed eval suite
- holdout datasets
- regression dashboard
- artifact comparison tooling
- promotion rules

### Stream 8: Research / optimization loop
Goal: let agents improve the system without destabilizing it.

Deliverables:
- experiment runner
- candidate proposal format
- benchmark comparison reports
- human-review checkpoints

---

## Phase Plan

## Phase 0 — Foundation / Alignment

### Objectives
- define the product clearly
- define measurable success
- set repo structure
- define contracts

### Tasks
1. Create `docs/product/prd.md`
2. Create `docs/product/benchmark-definition.md`
3. Create `docs/architecture/system-overview.md`
4. Create `docs/architecture/runtime-contracts.md`
5. Create ADR template
6. Define initial file support matrix
7. Define initial task taxonomy
8. Define performance budgets per platform

### Exit criteria
- product scope approved
- first benchmark suite defined
- contracts version `v0`
- repo structure created

---

## Phase 1 — Single-Document MVP Core

### Objectives
- support one document at a time
- answer questions with citations
- summarize and extract locally
- get baseline metrics

### Tasks
1. Build text normalization pipeline
2. Implement chunking with stable identifiers
3. Implement local lexical retrieval baseline
4. Add optional embedding retrieval path
5. Implement citation span generation
6. Define structured output schemas for:
   - summary
   - field extraction
   - answer with evidence
7. Build minimal eval dataset with 50–100 gold cases
8. Measure baseline latency / memory / answer quality

### Exit criteria
- one document can be imported locally
- answers include evidence
- summaries are stable enough for review
- evals run in CI or scripted local workflow

---

## Phase 2 — Apple-Native Flagship Path

### Objectives
- deliver best on-device Apple experience
- integrate local intelligence orchestration
- optimize performance on Apple hardware

### Tasks
1. Build Swift runtime shell
2. Implement document import and local storage
3. Implement query pipeline using shared contracts
4. Add structured extraction flows
5. Add summarization flows
6. Integrate local model orchestration layer
7. Add profiling for latency, memory, and battery
8. Validate offline behavior

### Exit criteria
- Apple app can perform core v1 jobs offline
- local outputs are benchmarked
- performance budgets are visible and tracked

---

## Phase 3 — Universal JavaScript Path

### Objectives
- support browser runtime
- maintain parity on core jobs
- validate model portability

### Tasks
1. Create TS runtime package for task execution
2. Implement browser document ingestion subset
3. Integrate browser-side inference strategy
4. Validate schema parity with Apple path
5. Create parity eval suite
6. Optimize bundle size and memory pressure

### Exit criteria
- web runtime can perform key v1 tasks
- shared eval cases run against both paths
- known parity gaps are documented

---

## Phase 4 — Controlled Improvement Loop

### Objectives
- enable agent-driven improvement proposals
- prevent quality regressions
- create repeatable release promotion

### Tasks
1. Define candidate proposal spec
2. Build experiment runner
3. Support candidate types:
   - prompt changes
   - retrieval tweaks
   - chunking changes
   - reranker changes
   - compact model updates
4. Compare candidates against stable baselines
5. Produce machine-readable eval reports
6. Require approval rules for promotion

### Exit criteria
- agents can propose and test changes safely
- no candidate ships without passing the gate
- promotion history is recorded

---

## Phase 5 — Multi-Document and Personal Knowledge Features

### Objectives
- move beyond single-document workflows
- enable collections / notebooks / projects
- preserve evidence quality

### Tasks
1. Add document collections
2. Add cross-document retrieval
3. Add source-aware citations
4. Add collection-level summarization
5. Add notebook / workspace abstraction
6. Expand evals to multi-document tasks

### Exit criteria
- user can query across multiple local documents
- citations identify source document and span
- eval coverage includes cross-doc reasoning

---

## Benchmarking Requirements

The orchestration agent must prioritize benchmark quality early.

### Minimum benchmark categories

1. **Extraction accuracy**
   - exact match
   - partial match
   - schema validity

2. **Question answering quality**
   - answer correctness
   - citation correctness
   - hallucination rate

3. **Summarization quality**
   - coverage
   - factual consistency
   - compression ratio

4. **Retrieval quality**
   - recall@k
   - MRR / nDCG where practical
   - citation span overlap

5. **Runtime quality**
   - p50 / p95 latency
   - peak memory
   - battery / energy proxy where possible
   - model load time

6. **Robustness**
   - long documents
   - malformed documents
   - scanned / messy content if later supported
   - adversarial / confusing phrasing

### Benchmark policy

- Every shipped change must compare against the current baseline.
- No model, prompt, chunking, or ranking change can be accepted without evidence.
- Track quality and performance together.
- “Feels better” is not sufficient.

---

## Candidate Improvement Loop

This is the safe way to use agents for system improvement.

### Inputs
- benchmark failures
- user feedback
- runtime telemetry
- regression reports
- missed extraction fields
- low-confidence answers

### Candidate types
- prompt variants
- chunking variants
- retrieval parameter changes
- reranker variants
- model quantization variants
- adapter candidates
- parsing heuristics
- document-type-specific policies

### Required process
1. agent identifies a weakness
2. agent proposes one or more candidate changes
3. agent generates an experiment plan
4. candidates run on fixed benchmark + holdout set
5. results are compared to current production baseline
6. only improvements that pass guardrails become releasable

### Guardrails
- no production auto-merge
- no silent benchmark changes to make candidates look better
- no shipping based on one metric alone
- no candidate that improves quality while blowing past memory budgets unless explicitly approved

---

## Acceptance Criteria By Layer

### Ingestion
- can import supported file types reliably
- normalization preserves section structure where possible
- chunk IDs remain stable across repeated runs

### Retrieval
- returns relevant evidence spans
- latency meets budget on target devices
- results are reproducible enough for evaluation

### Summarization
- structured summaries validate against schema
- no unsupported claims beyond source material in gold tests

### Extraction
- outputs valid schema consistently
- confidence / provenance available where possible

### QA
- answers grounded in retrieved evidence
- citations map to source spans
- abstains when evidence is insufficient

### Eval harness
- runs locally and in CI-like scripted environments
- stores comparable reports over time
- supports baseline vs candidate diffs

---

## Initial Success Metrics

These are starting targets. They can be revised by ADR.

### Quality
- extraction schema validity: >= 95%
- citation presence on evidence-based answers: >= 95%
- hallucination rate on benchmark QA: as low as possible, with abstention preferred over invention

### Performance
- first answer latency on representative local task: target defined per platform
- warm query latency lower than cold query latency and tracked separately
- peak memory within acceptable bounds for target devices

### Product
- single-document import to usable answer flow works end-to-end
- user can verify why the answer was produced
- app remains useful offline

---

## Risks And Countermeasures

### Risk: agentic overreach
Problem: the orchestration agent starts creating a sprawling multi-agent system before basics work.
Countermeasure: enforce phase gates and require benchmark-linked justification for new complexity.

### Risk: vendor lock-in
Problem: Apple path becomes the whole product.
Countermeasure: keep task schemas, evals, and core model contracts portable.

### Risk: JS path underperforms badly
Problem: browser runtime becomes a weak demo.
Countermeasure: scope browser features realistically and maintain parity only on core jobs at first.

### Risk: evaluation theater
Problem: metrics become shallow or gameable.
Countermeasure: include holdout sets, manual review slices, and regression tracking.

### Risk: parsing dominates quality issues
Problem: model quality is blamed when ingestion is broken.
Countermeasure: treat document normalization and evidence tracing as first-class work.

### Risk: performance death by model size
Problem: “better” models ruin latency, battery, and UX.
Countermeasure: track performance budgets from day one and prefer compact task-specific models.

---

## Immediate Next Actions For The Orchestration Agent

Execute these in order.

1. Create the repository skeleton from this plan.
2. Create the following files if missing:
   - `README.md`
   - `docs/product/prd.md`
   - `docs/product/benchmark-definition.md`
   - `docs/architecture/system-overview.md`
   - `docs/architecture/runtime-contracts.md`
   - `docs/ops/release-process.md`
3. Write `docs/product/prd.md` with v1 jobs, non-goals, target devices, and privacy principles.
4. Write `docs/product/benchmark-definition.md` with initial metrics and gold-task templates.
5. Define shared contracts for documents, chunks, citations, tasks, and eval cases.
6. Build the smallest possible single-document ingestion + retrieval + answer path.
7. Create 20 representative sample documents and 50–100 benchmark cases.
8. Produce the first baseline report.
9. Only after baseline exists, begin Apple-specific and JS-specific runtime work.

---

## Required Deliverables In The First Execution Cycle

By the end of the first serious implementation cycle, the agent should have produced:

- repo skeleton
- PRD
- benchmark definition
- runtime contracts
- first ADR if any major decision was needed
- single-document processing pipeline
- baseline eval dataset
- baseline metrics report
- prioritized backlog for Apple path and JS path

---

## Backlog Seeding

Seed the backlog with these epics.

### Epic 1 — Core contracts
- define schemas
- version contracts
- add validation tooling

### Epic 2 — Document ingestion
- local import
- parser abstraction
- chunking
- metadata extraction

### Epic 3 — Evidence-based answering
- retrieval baseline
- answer packaging
- citations
- abstention policy

### Epic 4 — Evaluation harness
- dataset format
- scoring scripts
- baseline reports
- candidate comparison reports

### Epic 5 — Apple runtime
- app shell
- local orchestration integration
- offline UX
- profiling

### Epic 6 — Web runtime
- browser shell
- local/browser inference
- parity tests
- bundle optimization

### Epic 7 — Improvement loop
- proposal spec
- experiment runner
- gating and promotion process

---

## Architecture Decision Record Triggers

Create an ADR whenever any of the following occurs:

- runtime model format changes
- chunking strategy changes materially
- retrieval stack changes materially
- Apple and JS contract divergence is proposed
- a new file type is added that impacts architecture
- cloud features are introduced for any core path
- a new local database/index strategy is chosen

---

## Definition Of Done

A task is not done unless all of the following are true:

1. code or docs are committed in the correct location
2. tests or validation steps exist where appropriate
3. benchmarks were run if behavior changed materially
4. contracts remain valid
5. task status is updated
6. assumptions and tradeoffs are documented

---

## Final Instruction To The Orchestration Agent

Build this system in a disciplined order.
Do not chase novelty over leverage.
Do not confuse agent activity with product progress.
The first real win is not “many agents.”
The first real win is:

- one document
- one solid local pipeline
- one benchmark harness
- one repeatable improvement loop

Everything else builds on that.
