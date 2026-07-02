# ``Scribe``

On-device PDF and EPUB extraction that produces reading-app-ready
structured chapters — no server, no network, no ML models.

## Overview

Scribe turns a document into `contentStructure` JSON: chapters with clean
plain text, HTML content, footnotes separated from body text, running
headers stripped, images as data URIs, and word-index positions computed by
a tokenizer that is parity-locked with its JavaScript twin
(`shared/tokenizer/parseText.js`).

The deterministic core (``ScribeProcessor``) uses only Apple frameworks and
is forbidden from network I/O. Optional NLP and Apple Intelligence
enrichment lives in ``DocumentIntelligence`` and never gates or alters the
deterministic output.

```swift
import Scribe

if let result = ScribeProcessor.extractContent(from: documentURL) {
    let chapters = result["chapters"] as! [[String: Any]]
    let hasStructure = result["hasStructure"] as! Bool
}
```

Extraction quality is measured against a hand-annotated corpus with locked
regression baselines — see `docs/benchmarks.md` in the repository for
measured latency and fidelity per book.

## Topics

### Extraction

- ``ScribeProcessor``

### Word indexing

- ``ScribeTokenizer``

### Optional enrichment

- ``DocumentIntelligence``
