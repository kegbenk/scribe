# Scribe Milestone Gates

Use these gates to keep `scribe` moving without pretending the API and evaluation surfaces are already stable.

## Current Milestone

Stabilize the extraction contract while the new document-intelligence layers are being added.

## Exit Criteria For This Milestone

1. `contentStructure` schema changes are intentional and documented.
2. CLI output still matches the schema contract.
3. at least one regression/eval pass is run against the corpus after major extraction changes.
4. consumer expectations are written down for downstream apps.
5. new intelligence modules do not bypass the baseline extraction path silently.

## Not Yet A Release Gate

The repo should not be treated as stable-for-external-consumers until:

1. schema churn slows down
2. regression runs are repeatable
3. one consumer contract is documented and exercised end-to-end

## Immediate Next Decision

Decide whether the current document-intelligence additions are:

- part of the default extraction pipeline
- optional enrichments
- an experimental branch of the library
