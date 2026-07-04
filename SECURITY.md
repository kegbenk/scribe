# Security Policy

## Supported versions

The latest tagged 0.x release receives fixes. Older tags are not patched.

## Reporting a vulnerability

Scribe parses untrusted documents (PDF and ZIP/EPUB containers), so parsing
bugs with security impact — memory unsafety in the zip reader, crashes on
crafted inputs, path traversal via archive entry names — are in scope and
taken seriously.

**Please do not open a public issue for security reports.** Use GitHub's
private vulnerability reporting ("Report a vulnerability" under the Security
tab), or email kegbenk@gmail.com with a description and a reproducing input
if you have one.

You'll get an acknowledgment within a week. Fixes ship as a patch release
with credit unless you prefer otherwise.

## Design notes relevant to security

- Extraction performs no network I/O (enforced in CI by
  `tools/privacy-audit.sh`).
- The zip reader rejects encrypted entries and zip64 archives rather than
  attempting partial parses.
- Archive paths are normalized (`.`/`..` components resolved) before lookup;
  entries are read from the central directory, never extracted to disk.
