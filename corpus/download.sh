#!/usr/bin/env bash
#
# Download PDF test corpus for fidelity testing.
# Source PDFs are gitignored — run this after cloning.
#
# Usage:
#   bash tests/pdf-fidelity/download-corpus.sh           # all books
#   bash tests/pdf-fidelity/download-corpus.sh sherlock-holmes  # single book
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A URLS=(
  [self-help-smiles]="https://archive.org/download/selfhelpwithillu00smilrich/selfhelpwithillu00smilrich.pdf"
  [sherlock-holmes]="https://archive.org/download/adventures-sherlock-holmes/adventures-sherlock-holmes.pdf"
  [astronomy-textbook]="https://assets.openstax.org/oscms-prodcms/media/documents/Astronomy2e-WEB.pdf"
  [attention-paper]="https://arxiv.org/pdf/1706.03762"
  [alice-wonderland]="https://archive.org/download/adventuresalices00carrrich/adventuresalices00carrrich.pdf"
  [911-commission]="https://www.govinfo.gov/content/pkg/GPO-911REPORT/pdf/GPO-911REPORT.pdf"
  [anatomy-melancholy]="https://archive.org/download/anatomyofmelanch1868burt/anatomyofmelanch1868burt.pdf"
)

FILTER="${1:-all}"

downloaded=0
skipped=0
failed=0

for slug in "${!URLS[@]}"; do
  if [[ "$FILTER" != "all" && "$FILTER" != "$slug" ]]; then
    continue
  fi

  dest="$SCRIPT_DIR/$slug/source.pdf"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    size=$(du -h "$dest" | cut -f1)
    echo "  skip  $slug ($size already exists)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "  fetch $slug ..."
  if curl -fSL -o "$dest" "${URLS[$slug]}" 2>/dev/null; then
    size=$(du -h "$dest" | cut -f1)
    echo "  done  $slug ($size)"
    downloaded=$((downloaded + 1))
  else
    echo "  FAIL  $slug"
    rm -f "$dest"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Downloaded: $downloaded | Skipped: $skipped | Failed: $failed"
