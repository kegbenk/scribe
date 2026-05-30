# Scribe — Privacy Principles

The competitive position of Scribe is "your documents never leave your device." These principles are load-bearing for the product, not aspirational marketing. Code review should reject anything that violates them silently.

## Non-negotiable principles

1. **No document bytes leave the device in the default path. Ever.**
   `ScribeProcessor` and `DocumentIntelligence` MUST NOT perform any network I/O on the document, its extracted text, or any derivative (chunks, embeddings, summaries, entities). No telemetry that includes document content.

2. **No remote inference in the default path.**
   All extraction (PDFKit, Vision OCR, XObject parsing) is local. All intelligence layers (`NaturalLanguage`, `FoundationModels`, `Vision.RecognizeDocumentsRequest`) are on-device Apple frameworks. If a future feature needs a remote model, it ships behind an explicit opt-in per-document or per-session, and is documented in an ADR.

3. **No silent persistence beyond what the consumer asks for.**
   Scribe is a library. It returns extraction results to the caller and does not write to disk, write to a database, or cache document content unless the caller explicitly asks for it via an API that names what's being stored and where.

4. **No analytics on document content.**
   Anonymous error / crash reporting that contains zero document content is acceptable if explicitly designed. Logging that includes extracted text, entity names, page snippets, or filenames is not.

5. **Opt-in for any future cloud features.**
   If a remote feature is added (e.g., a hosted reranker, a remote summarizer), it must:
   - be off by default
   - be enabled per-document or per-session, not as a global setting
   - be visible in the API surface (no hidden flag)
   - have its own ADR

## How this constrains design

- `ScribeProcessor` cannot import any networking framework (no `URLSession`, no third-party HTTP client).
- `DocumentIntelligence` is bound to Apple's on-device frameworks. Any future "intelligence" candidate that requires a network call is rejected at design time, regardless of quality gains.
- Telemetry / logging code in this repo SHOULD assume that any string it touches might be document content and treat it as PII.

## Consumer responsibilities

Scribe is a library. Consumers (`rsvp-reader`, `velo-macos`, future apps) are responsible for:

- Not transmitting extraction results to a server unless the user has opted in
- Not persisting extraction results outside the user's own device unless the user has asked for it
- Surfacing in their own UI when Apple Intelligence (FoundationModels) is or isn't available

Scribe's contract is "the bytes don't leave because of us." It cannot enforce what consumers do with the returned `contentStructure`.

## Review triggers

A PR triggers a privacy review if it:

- Adds an `import` for a networking framework
- Adds a dependency in `Package.swift` not previously present
- Adds a logging call that includes any string derived from PDF content
- Adds persistence (disk, keychain, UserDefaults) of any extracted content
- Proposes a remote feature (must come with an ADR)

## Audit checklist (run before each tag)

- `grep -r 'URLSession\|http://\|https://\|fetch\|NWConnection' swift/Sources/Scribe/` returns no hits outside of comments / doc URLs.
- `Package.swift` has no new external dependencies since the last tag.
- New logging call sites do not include document-content strings.

This is a manual audit until a CI rule exists. Tracked on backlog.
