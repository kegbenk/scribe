/**
 * Fidelity scorer — compares native.json against AI-predicted contentStructure.
 *
 * Seven dimensions tuned for epub-like fidelity.
 */

import { parseText } from '../shared/tokenizer/parseText.js';

// ---------------------------------------------------------------------------
// Helpers (reused patterns from pdf-test-factory/scorer.js)
// ---------------------------------------------------------------------------

function jaccard(a, b) {
  if (a.size === 0 && b.size === 0) return 1;
  const intersection = new Set([...a].filter(x => b.has(x)));
  const union = new Set([...a, ...b]);
  return intersection.size / union.size;
}

function normalizeTitle(title) {
  return String(title || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

function fuzzyTitleMatch(a, b) {
  const na = normalizeTitle(a);
  const nb = normalizeTitle(b);
  if (na === nb) return 1;
  // Check if one contains the other
  if (na.includes(nb) || nb.includes(na)) return 0.8;
  // Jaccard on words
  const wa = new Set(na.split(/\s+/));
  const wb = new Set(nb.split(/\s+/));
  return jaccard(wa, wb);
}

function getParagraphs(chapter) {
  if (Array.isArray(chapter.paragraphs)) return chapter.paragraphs;
  if (typeof chapter.plainText === 'string') {
    return chapter.plainText.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
  }
  return [];
}

function getPlainText(chapter) {
  return chapter.plainText || getParagraphs(chapter).join('\n\n');
}

function getFootnotes(chapter) {
  return Array.isArray(chapter.footnotes) ? chapter.footnotes : [];
}

// ---------------------------------------------------------------------------
// Dimensions
// ---------------------------------------------------------------------------

const DIMENSIONS = [
  {
    name: 'chapter_boundaries',
    weight: 0.18,
    score(predicted, native) {
      const pStarts = new Set(predicted.chapters.map(c => c.startPage));
      const nStarts = new Set(native.chapters.map(c => c.startPage));

      if (pStarts.size === 0 && nStarts.size === 0) return 1;
      if (pStarts.size === 0 || nStarts.size === 0) return 0;

      // Allow ±1 page tolerance
      let matched = 0;
      for (const p of pStarts) {
        if (nStarts.has(p) || nStarts.has(p - 1) || nStarts.has(p + 1)) {
          matched++;
        }
      }

      const precision = matched / nStarts.size;
      const recall = matched / pStarts.size;
      if (precision + recall === 0) return 0;
      return (2 * precision * recall) / (precision + recall);
    }
  },
  {
    name: 'chapter_titles',
    weight: 0.13,
    score(predicted, native) {
      const pTitles = predicted.chapters.map(c => c.title);
      const nTitles = native.chapters.map(c => c.title);

      if (pTitles.length === 0 && nTitles.length === 0) return 1;
      if (pTitles.length === 0 || nTitles.length === 0) return 0;

      // Best fuzzy match for each predicted title
      let totalScore = 0;
      const used = new Set();

      for (const pt of pTitles) {
        let bestScore = 0;
        let bestIdx = -1;
        for (let i = 0; i < nTitles.length; i++) {
          if (used.has(i)) continue;
          const s = fuzzyTitleMatch(pt, nTitles[i]);
          if (s > bestScore) {
            bestScore = s;
            bestIdx = i;
          }
        }
        if (bestIdx >= 0) {
          used.add(bestIdx);
          totalScore += bestScore;
        }
      }

      const maxLen = Math.max(pTitles.length, nTitles.length);
      return totalScore / maxLen;
    }
  },
  {
    name: 'footnote_separation',
    weight: 0.18,
    score(predicted, native) {
      // Two sub-scores:
      // (a) Footnote body text should NOT leak into native body (existing check)
      // (b) Inline reference markers (superscripts) should be cleanly handled —
      //     the nearText context from AI should appear in native body WITHOUT
      //     the reference number jammed into a word

      const predictedFootnotes = predicted.chapters.flatMap(c => getFootnotes(c));
      const predictedRefs = predicted.chapters.flatMap(c => c.footnoteReferences || []);

      if (predictedFootnotes.length === 0 && predictedRefs.length === 0) return 1;

      // (a) Footnote body text leak check
      let leakedCount = 0;
      let checkedFn = 0;
      for (const fn of predictedFootnotes) {
        const fnText = fn.text?.slice(0, 50) || '';
        if (fnText.length < 10) continue;
        checkedFn++;

        for (const ch of native.chapters) {
          const body = getPlainText(ch);
          const hasEndnotes = getFootnotes(ch).length > 0;
          if (body.includes(fnText.slice(0, 30)) && !hasEndnotes) {
            leakedCount++;
            break;
          }
        }
      }
      const leakScore = checkedFn === 0 ? 1 : Math.max(0, 1 - leakedCount / checkedFn);

      // (b) Inline reference marker check — look for reference numbers
      //     jammed into body words (e.g., "alchemy1" or "fire2the")
      let refChecked = 0;
      let refClean = 0;
      const fullNativeBody = native.chapters.map(c => getPlainText(c)).join('\n');

      for (const ref of predictedRefs) {
        if (!ref.nearText || ref.nearText.length < 5) continue;
        refChecked++;

        // Extract a few words before the reference marker from nearText
        // The nearText looks like "...word alchemy¹ appears..."
        // Check if native has the reference number fused into a word
        const num = String(ref.number);
        // Look for patterns like "word<num>" (no space) in native body
        // near the context words
        const contextWords = ref.nearText
          .replace(/[¹²³⁴⁵⁶⁷⁸⁹⁰\d]/g, '')
          .split(/\s+/)
          .filter(w => w.length > 3)
          .slice(0, 3);

        if (contextWords.length === 0) { refClean++; continue; }

        // Find the context in native text
        const searchWord = contextWords[0].toLowerCase();
        const nativeLower = fullNativeBody.toLowerCase();
        const pos = nativeLower.indexOf(searchWord);
        if (pos < 0) { refClean++; continue; } // Context not found — can't check

        // Check a window around the match for fused reference numbers
        const windowStart = Math.max(0, pos - 50);
        const windowEnd = Math.min(fullNativeBody.length, pos + 100);
        const window = fullNativeBody.slice(windowStart, windowEnd);

        // Fused pattern: letter immediately followed by the ref number with no space
        const fusedPattern = new RegExp(`[a-zA-Z]${num}[a-zA-Z]|[a-zA-Z]${num}\\s`);
        if (!fusedPattern.test(window)) {
          refClean++;
        }
      }
      const refScore = refChecked === 0 ? 1 : refClean / refChecked;

      // Weighted combination: 60% leak check, 40% reference marker cleanliness
      return leakScore * 0.6 + refScore * 0.4;
    }
  },
  {
    name: 'running_header_clean',
    weight: 0.09,
    score(predicted, native) {
      // Collect running header texts from AI predictions
      const runningHeaders = new Set();
      for (const page of (predicted._annotations || [])) {
        for (const region of (page.regions || [])) {
          if (region.type === 'running_header' && region.text) {
            const text = region.text.trim();
            if (text.length > 5) runningHeaders.add(text);
          }
        }
      }

      if (runningHeaders.size === 0) return 1; // Can't check without header data

      // Check native body for standalone running header lines
      let headerCount = 0;
      let totalLines = 0;

      for (const ch of native.chapters) {
        const lines = getPlainText(ch).split('\n');
        totalLines += lines.length;
        for (const line of lines) {
          const trimmed = line.trim();
          for (const header of runningHeaders) {
            if (trimmed === header || trimmed.replace(/\d+/g, '').trim() === header) {
              headerCount++;
            }
          }
        }
      }

      if (totalLines === 0) return 1;
      // Score: penalize based on ratio of header lines to total
      return Math.max(0, 1 - (headerCount / Math.max(1, totalLines)) * 100);
    }
  },
  {
    name: 'body_text_completeness',
    weight: 0.14,
    score(predicted, native) {
      const pWordCount = predicted.chapters.reduce((s, c) => {
        const text = getPlainText(c);
        return s + parseText(text).length;
      }, 0);

      const nWordCount = native.chapters.reduce((s, c) => {
        const text = getPlainText(c);
        return s + parseText(text).length;
      }, 0);

      if (pWordCount === 0 && nWordCount === 0) return 1;
      if (pWordCount === 0) return 0;

      const ratio = nWordCount / pWordCount;
      // Ideal ratio is 1.0. Penalize divergence.
      return Math.max(0, 1 - Math.abs(1 - ratio));
    }
  },
  {
    name: 'reading_order',
    weight: 0.09,
    score(predicted, native) {
      // For two-column pages, check that native preserves correct column order
      const twoColPages = (predicted._annotations || [])
        .filter(p => p.layout === 'two_column');

      if (twoColPages.length === 0) return 1;

      let correctOrder = 0;
      let checked = 0;

      for (const page of twoColPages) {
        const bodyRegions = (page.regions || [])
          .filter(r => r.type === 'body')
          .sort((a, b) => (a.readingOrder || 0) - (b.readingOrder || 0));

        if (bodyRegions.length < 2) continue;

        // Get first few words from each region
        const firstWords = bodyRegions[0].text?.split(/\s+/).slice(0, 5).join(' ') || '';
        if (firstWords.length < 10) continue;

        // Check if native text has these words in the right order
        const fullNativeText = native.chapters.map(c => getPlainText(c)).join('\n');
        const pos = fullNativeText.indexOf(firstWords);
        if (pos >= 0) correctOrder++;
        checked++;
      }

      return checked === 0 ? 1 : correctOrder / checked;
    }
  },
  {
    name: 'back_matter_detection',
    weight: 0.09,
    score(predicted, native) {
      const pBackMatter = predicted.chapters.filter(c => c.isBackMatter);
      const nBackMatter = native.chapters.filter(c => {
        const title = (c.title || '').toLowerCase();
        return c.isBackMatter
          || title.includes('bibliography')
          || title.includes('index')
          || title.includes('appendix')
          || title.includes('notes')
          || title.includes('references');
      });

      if (pBackMatter.length === 0 && nBackMatter.length === 0) return 1;
      if (pBackMatter.length === 0) return 0.5; // Can't score if AI didn't detect any

      // Check: does native have any back-matter chapters?
      if (nBackMatter.length === 0 && pBackMatter.length > 0) return 0;

      // F1 on count
      const pCount = pBackMatter.length;
      const nCount = nBackMatter.length;
      const matched = Math.min(pCount, nCount);
      const precision = matched / nCount;
      const recall = matched / pCount;
      if (precision + recall === 0) return 0;
      return (2 * precision * recall) / (precision + recall);
    }
  },
  {
    name: 'ocr_quality',
    weight: 0.10,
    score(predicted, native) {
      // Score = 1.0 minus garbage character ratio across all native chapters.
      // Garbage = characters outside normal prose range (letters, digits, whitespace,
      // standard punctuation, common typographic chars).
      let totalChars = 0;
      let garbageChars = 0;

      for (const ch of native.chapters) {
        const text = getPlainText(ch);
        totalChars += text.length;
        // Count chars that are NOT normal prose characters
        garbageChars += text.replace(/[\w\s.,;:!?'"()\-\u2014\u2013\u2018\u2019\u201c\u201d\u2026\n\r\t\u00a0/[\]{}@#$%&*+=<>~`^|\\]/g, '').length;
      }

      if (totalChars === 0) return 1;
      const garbageRatio = garbageChars / totalChars;
      return Math.max(0, 1 - garbageRatio * 10); // 10% garbage → score 0
    }
  }
];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Score native contentStructure against AI-predicted contentStructure.
 *
 * @param {object} predicted - AI-predicted contentStructure (with optional _annotations)
 * @param {object} native - Native parser output contentStructure
 * @param {number} [threshold=0.90] - Minimum overall score to pass
 * @returns {{ overall: number, pass: boolean, dimensions: object[], threshold: number }}
 */
export function scoreFidelity(predicted, native, threshold = 0.90) {
  const dimensions = DIMENSIONS.map(dim => {
    const value = dim.score(predicted, native);
    return {
      name: dim.name,
      score: value,
      weight: dim.weight,
      weighted: value * dim.weight
    };
  });

  const overall = dimensions.reduce((sum, d) => sum + d.weighted, 0);

  return {
    overall,
    pass: overall >= threshold,
    threshold,
    dimensions
  };
}

/**
 * Format a fidelity report for console output.
 */
export function formatFidelityReport(bookSlug, result) {
  const lines = [];
  lines.push(`\n--- ${bookSlug} (AI Fidelity) ---`);
  for (const d of result.dimensions) {
    const pct = (d.score * 100).toFixed(1);
    const bar = d.score >= 0.80 ? 'PASS' : 'FAIL';
    lines.push(`  ${d.name.padEnd(24)} ${pct.padStart(6)}%  (w=${d.weight})  [${bar}]`);
  }
  const overallPct = (result.overall * 100).toFixed(1);
  const status = result.pass ? 'PASS' : 'FAIL';
  lines.push(`  ${'OVERALL'.padEnd(24)} ${overallPct.padStart(6)}%  threshold=${(result.threshold * 100).toFixed(0)}%  [${status}]`);
  return lines.join('\n');
}
