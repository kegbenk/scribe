/**
 * Prompt templates for PDF fidelity AI analysis.
 * Each prompt version is hashed for cache invalidation.
 */

import { createHash } from 'crypto';

export const PROMPT_VERSION = 'v2';

/**
 * System prompt for per-spread page analysis.
 */
export const SYSTEM_PROMPT = `You are a document layout analyst. You analyze PDF page images and identify structural elements for conversion to an epub-like reading experience.

Your job is to identify:
1. Chapter boundaries (title pages, chapter headings)
2. Body text regions and their reading order
3. Footnotes (typically smaller text at page bottom, numbered) and their inline reference markers (superscript numbers in body text)
4. Running headers (repeated text at page top — book title, chapter title)
5. Page numbers (typically at top or bottom corners)
6. Images, figures, and captions
7. Back matter (bibliography, index, appendix, notes)

For two-column layouts, identify left and right columns separately and specify reading order.

Be precise about what you see. If uncertain, lower your confidence score.`;

/**
 * User prompt for analyzing a spread (1-2 pages).
 * @param {number[]} pageNumbers - 1-based page numbers
 * @param {boolean} isFirstPages - Whether these are the first pages of the book
 */
export function spreadPrompt(pageNumbers, isFirstPages = false) {
  const pageLabel = pageNumbers.length === 1
    ? `page ${pageNumbers[0]}`
    : `pages ${pageNumbers[0]}-${pageNumbers[1]}`;

  const firstPageContext = isFirstPages
    ? '\nThese are the first pages of the book. Look for title pages, copyright pages, table of contents, or other front matter.'
    : '';

  return `Analyze ${pageLabel} of this PDF.${firstPageContext}

For EACH page visible, provide a JSON object with this exact schema:

{
  "pageNumber": <1-based page number>,
  "layout": "single_column" or "two_column",
  "isChapterStart": <true if this page begins a new chapter>,
  "chapterTitle": <string or null — the chapter title if isChapterStart>,
  "isBackMatter": <true if this is bibliography, index, appendix, or endnotes>,
  "backMatterType": <"bibliography"|"index"|"appendix"|"endnotes"|"glossary"|null>,
  "hasFootnotes": <true if page has footnotes at the bottom>,
  "footnoteNumbers": [<list of footnote reference numbers visible>],
  "footnoteReferences": [
    {
      "number": <the superscript/reference number>,
      "nearText": "<~10 words surrounding the inline reference marker in body text>",
      "column": "left|right|full"
    }
  ],
  "regions": [
    {
      "type": "body|footnote|heading|running_header|page_number|image|chapter_title|back_matter|front_matter",
      "readingOrder": <integer, 1-based>,
      "text": "<transcribed text of this region — first ~200 chars for body, full text for headings/footnotes>",
      "column": "left|right|full",
      "confidence": <0.0-1.0>
    }
  ]
}

Return a JSON array with one object per page. If two pages are shown, return an array of two objects.
Important: Return ONLY the JSON array, no markdown fencing or explanation.`;
}

/**
 * Triage prompt — lightweight classification only, no regions/text.
 * Designed for max_tokens=512, completes in ~27s at 19 tok/s.
 */
export function triagePrompt(pageNumber, opts = {}) {
  const bookContext = opts.bookTitle
    ? `Book: "${opts.bookTitle}"${opts.bookAuthor ? ` by ${opts.bookAuthor}` : ''}.`
    : '';

  let chapterHint = '';
  if (opts.tocEntries?.length) {
    const titles = opts.tocEntries.slice(0, 8).map(e => `"${e.title}"`).join(', ');
    chapterHint = `Known chapters: ${titles}${opts.tocEntries.length > 8 ? ', ...' : ''}.
If this page starts one of these chapters, use the exact title.`;
  }

  return `Classify page ${pageNumber} of this PDF.
${bookContext}
${chapterHint}

Return a JSON object:
{
  "pageNumber": ${pageNumber},
  "layout": "single_column" or "two_column",
  "isChapterStart": <true ONLY if a large chapter heading is clearly visible>,
  "chapterTitle": <the chapter heading text if isChapterStart, else null>,
  "isBackMatter": <true if bibliography, index, appendix, or endnotes>,
  "backMatterType": <"bibliography"|"index"|"appendix"|"endnotes"|"glossary"|null>,
  "hasFootnotes": <true if footnotes at bottom of page>
}

Return ONLY JSON, no markdown fencing or explanation.`;
}

/**
 * Detail prompt — full analysis for interesting pages.
 * Same schema as spreadPrompt but single-page and capped at 2048 tokens.
 */
export function detailPrompt(pageNumber, opts = {}) {
  const bookContext = opts.bookTitle
    ? `Book: "${opts.bookTitle}"${opts.bookAuthor ? ` by ${opts.bookAuthor}` : ''}.`
    : '';

  let chapterHint = '';
  if (opts.tocEntries?.length) {
    const titles = opts.tocEntries.slice(0, 8).map(e => `"${e.title}"`).join(', ');
    chapterHint = `Known chapters: ${titles}${opts.tocEntries.length > 8 ? ', ...' : ''}.
If this page starts one of these chapters, use the exact title.`;
  }

  return `Analyze page ${pageNumber} of this PDF in detail.
${bookContext}
${chapterHint}

Return a JSON object:
{
  "pageNumber": ${pageNumber},
  "layout": "single_column" or "two_column",
  "isChapterStart": <true ONLY if a large chapter heading is clearly visible>,
  "chapterTitle": <heading text if isChapterStart, else null>,
  "isBackMatter": <true if bibliography, index, appendix, or endnotes>,
  "backMatterType": <"bibliography"|"index"|"appendix"|"endnotes"|"glossary"|null>,
  "hasFootnotes": <true if footnotes at bottom>,
  "footnoteNumbers": [<footnote reference numbers visible>],
  "footnoteReferences": [
    {"number": <ref number>, "nearText": "<~10 words around the marker>", "column": "left|right|full"}
  ],
  "regions": [
    {
      "type": "body|footnote|heading|running_header|page_number|image|chapter_title|back_matter|front_matter",
      "readingOrder": <integer, 1-based>,
      "text": "<first ~200 chars for body, full text for headings/footnotes>",
      "column": "left|right|full",
      "confidence": <0.0-1.0>
    }
  ]
}

Return ONLY JSON, no markdown fencing or explanation.`;
}

/**
 * Compute a hash of the prompt templates for cache keying.
 */
export function promptHash() {
  const content = SYSTEM_PROMPT + PROMPT_VERSION + spreadPrompt([1], true) + spreadPrompt([2, 3]);
  return createHash('sha256').update(content).digest('hex').slice(0, 12);
}

export function triagePromptHash() {
  const content = 'triage-v1' + triagePrompt(1);
  return createHash('sha256').update(content).digest('hex').slice(0, 12);
}

export function detailPromptHash() {
  const content = 'detail-v1' + detailPrompt(1);
  return createHash('sha256').update(content).digest('hex').slice(0, 12);
}
