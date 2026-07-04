## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `swift test --package-path swift` green
- [ ] `node eval/regression.js` green (schema validation + fidelity gate)
- [ ] `tools/privacy-audit.sh` passes
- [ ] Public API impact stated (run `tools/api-diff.sh`): none / additive / breaking
- [ ] If extraction output changed: corpus regenerated and affected `predicted.json` committed; unaffected scanned-book churn excluded
- [ ] If architecture changed: ADR added or updated
