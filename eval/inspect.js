#!/usr/bin/env node
/**
 * Offline anomaly detector for native.json — no simulator needed.
 * Analyzes VeloPDFProcessor output for common rendering problems:
 * running header leakage, OCR garbage, stub paragraphs, image issues,
 * title garbling, missing breaks, word count anomalies, duplicate text.
 *
 * Usage:
 *   node eval/inspect.js alice-wonderland
 *   node eval/inspect.js           # all books
 *   node eval/inspect.js --json     # JSON output
 */

import { existsSync, readFileSync, writeFileSync, readdirSync } from 'fs';
import { join, resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = resolve(__dirname, '..');
const FIDELITY_DIR = join(ROOT, 'corpus');

// Parse args
const args = process.argv.slice(2);
let jsonOutput = false;
const slugs = [];

for (const arg of args) {
  if (arg === '--json') { jsonOutput = true; continue; }
  if (!arg.startsWith('-')) slugs.push(arg);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getPlainText(chapter) {
  return chapter.plainText || (Array.isArray(chapter.paragraphs)
    ? chapter.paragraphs.join('\n\n')
    : '');
}

function getParagraphs(chapter) {
  if (Array.isArray(chapter.paragraphs)) return chapter.paragraphs;
  if (typeof chapter.plainText === 'string') {
    return chapter.plainText.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
  }
  return [];
}

// ---------------------------------------------------------------------------
// 8 Anomaly Detectors
// ---------------------------------------------------------------------------

function detectRunningHeaderLeakage(native) {
  const anomalies = [];
  const chapterCount = native.chapters.length;
  if (chapterCount < 3) return anomalies;

  // Collect short lines across all chapters
  const lineCounts = {};
  for (const ch of native.chapters) {
    const lines = getPlainText(ch).split('\n');
    const seen = new Set(); // dedupe within chapter
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length >= 5 && trimmed.length < 70
          && !/[.!?]["')\]]*\s*$/.test(trimmed)) {
        const normalized = trimmed
          .replace(/^\d{1,4}\s*\^?\s*/, '')
          .replace(/\s*\^?\s*\d{1,4}$/, '')
          .trim();
        if (normalized.length >= 5 && !seen.has(normalized)) {
          seen.add(normalized);
          lineCounts[normalized] = (lineCounts[normalized] || 0) + 1;
        }
      }
    }
  }

  const threshold = Math.max(3, Math.floor(chapterCount * 0.3));
  for (const [text, count] of Object.entries(lineCounts)) {
    if (count >= threshold) {
      anomalies.push({
        detector: 'running_header_leakage',
        severity: 'HIGH',
        message: `Repeated short phrase in ${count}/${chapterCount} chapters: "${text.slice(0, 60)}"`,
        count
      });
    }
  }
  return anomalies;
}

function detectOCRGarbageRatio(native) {
  const anomalies = [];
  for (const ch of native.chapters) {
    const text = getPlainText(ch);
    if (text.length < 50) continue;

    const total = text.length;
    const garbage = text.replace(/[\w\s.,;:!?'"()\-\u2014\u2013\u2018\u2019\u201c\u201d]/g, '').length;
    const ratio = garbage / total;

    if (ratio > 0.05) {
      anomalies.push({
        detector: 'ocr_garbage_ratio',
        severity: ratio > 0.15 ? 'HIGH' : 'MEDIUM',
        message: `Chapter "${(ch.title || '').slice(0, 40)}": ${(ratio * 100).toFixed(1)}% non-standard characters`,
        chapter: ch.title,
        ratio
      });
    }
  }
  return anomalies;
}

function detectStubParagraphs(native) {
  const anomalies = [];
  for (const ch of native.chapters) {
    const paras = getParagraphs(ch);
    const stubs = paras.filter(p => p.trim().length < 5 && p.trim().length > 0);
    if (stubs.length > 3) {
      anomalies.push({
        detector: 'stub_paragraph',
        severity: stubs.length > 10 ? 'HIGH' : 'MEDIUM',
        message: `Chapter "${(ch.title || '').slice(0, 40)}": ${stubs.length} stub paragraphs (<5 chars)`,
        chapter: ch.title,
        count: stubs.length,
        examples: stubs.slice(0, 5).map(s => `"${s.trim()}"`)
      });
    }
  }
  return anomalies;
}

function detectImageOrientation(native) {
  const anomalies = [];
  const allImages = native.chapters.flatMap(ch => ch.images || []);
  if (allImages.length < 3) return anomalies;

  // Check if all images have identical dimensions (full-page render fallback)
  const dims = allImages.map(img => `${img.width}x${img.height}`);
  const unique = new Set(dims);
  if (unique.size === 1 && allImages.length >= 5) {
    anomalies.push({
      detector: 'image_orientation',
      severity: 'MEDIUM',
      message: `All ${allImages.length} images have identical dimensions (${dims[0]}) — possible full-page render fallback`,
      count: allImages.length
    });
  }
  return anomalies;
}

function detectTitleGarbling(native) {
  const anomalies = [];
  // Simple heuristic: flag titles with >30% non-alpha chars (excluding roman numerals, spaces, common punctuation)
  for (const ch of native.chapters) {
    const title = ch.title || '';
    if (title.length < 3) continue;

    // Remove expected chars: letters, digits, spaces, periods, hyphens, colons, commas, apostrophes
    const cleaned = title.replace(/[a-zA-Z0-9\s.,:;'\-—–()]/g, '');
    const ratio = cleaned.length / title.length;

    if (ratio > 0.3) {
      anomalies.push({
        detector: 'title_garbling',
        severity: 'HIGH',
        message: `Garbled chapter title: "${title}"`,
        chapter: title,
        ratio
      });
    }

    // Also check for all-caps with OCR-style substitutions
    if (/^[A-Z\s]+$/.test(title) === false && /^[A-Z]/.test(title)) {
      const words = title.split(/\s+/);
      const garbled = words.filter(w => w.length > 3 && /[^a-zA-Z0-9'\-]/.test(w));
      if (garbled.length > 0 && garbled.length / words.length > 0.3) {
        anomalies.push({
          detector: 'title_garbling',
          severity: 'MEDIUM',
          message: `Possible OCR errors in title: "${title}" (garbled words: ${garbled.join(', ')})`,
          chapter: title
        });
      }
    }
  }
  return anomalies;
}

function detectMissingParagraphBreaks(native) {
  const anomalies = [];
  for (const ch of native.chapters) {
    const text = getPlainText(ch);
    const wordCount = text.split(/\s+/).filter(Boolean).length;
    const hasBreaks = text.includes('\n\n');

    if (wordCount > 500 && !hasBreaks) {
      anomalies.push({
        detector: 'missing_paragraph_breaks',
        severity: 'HIGH',
        message: `Chapter "${(ch.title || '').slice(0, 40)}": ${wordCount} words with no paragraph breaks`,
        chapter: ch.title,
        wordCount
      });
    }
  }
  return anomalies;
}

function detectWordCountAnomaly(native) {
  const anomalies = [];
  const wordCounts = native.chapters.map(ch => {
    const text = getPlainText(ch);
    return text.split(/\s+/).filter(Boolean).length;
  });

  if (wordCounts.length < 3) return anomalies;

  const sorted = [...wordCounts].sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];

  for (let i = 0; i < native.chapters.length; i++) {
    const count = wordCounts[i];
    const title = native.chapters[i].title || `Chapter ${i + 1}`;

    if (count < 50 && count > 0) {
      anomalies.push({
        detector: 'word_count_anomaly',
        severity: 'MEDIUM',
        message: `Chapter "${title.slice(0, 40)}": only ${count} words (suspiciously short)`,
        chapter: title,
        wordCount: count,
        median
      });
    }

    if (median > 0 && count > median * 10) {
      anomalies.push({
        detector: 'word_count_anomaly',
        severity: 'HIGH',
        message: `Chapter "${title.slice(0, 40)}": ${count} words (${(count / median).toFixed(1)}x median of ${median})`,
        chapter: title,
        wordCount: count,
        median
      });
    }
  }
  return anomalies;
}

function detectDuplicateText(native) {
  const anomalies = [];
  const WINDOW = 20; // 20-word sequences

  // Build sequences per chapter
  const chapterSequences = native.chapters.map((ch, idx) => {
    const words = getPlainText(ch).split(/\s+/).filter(Boolean);
    const seqs = new Set();
    for (let i = 0; i <= words.length - WINDOW; i++) {
      seqs.add(words.slice(i, i + WINDOW).join(' ').toLowerCase());
    }
    return { idx, title: ch.title || `Chapter ${idx + 1}`, seqs };
  });

  // Check for cross-chapter duplicates
  for (let i = 0; i < chapterSequences.length; i++) {
    for (let j = i + 1; j < chapterSequences.length; j++) {
      let dupeCount = 0;
      for (const seq of chapterSequences[i].seqs) {
        if (chapterSequences[j].seqs.has(seq)) dupeCount++;
      }

      if (dupeCount > 3) {
        anomalies.push({
          detector: 'duplicate_text',
          severity: dupeCount > 20 ? 'HIGH' : 'MEDIUM',
          message: `${dupeCount} duplicate ${WINDOW}-word sequences between "${chapterSequences[i].title.slice(0, 30)}" and "${chapterSequences[j].title.slice(0, 30)}"`,
          chapters: [chapterSequences[i].title, chapterSequences[j].title],
          count: dupeCount
        });
      }
    }
  }
  return anomalies;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const ALL_DETECTORS = [
  detectRunningHeaderLeakage,
  detectOCRGarbageRatio,
  detectStubParagraphs,
  detectImageOrientation,
  detectTitleGarbling,
  detectMissingParagraphBreaks,
  detectWordCountAnomaly,
  detectDuplicateText,
];

function inspectBook(slug) {
  const nativePath = join(FIDELITY_DIR, slug, 'native.json');
  if (!existsSync(nativePath)) {
    console.error(`No native.json found for ${slug}`);
    return null;
  }

  const native = JSON.parse(readFileSync(nativePath, 'utf-8'));
  const anomalies = ALL_DETECTORS.flatMap(fn => fn(native));

  const summary = {
    high: anomalies.filter(a => a.severity === 'HIGH').length,
    medium: anomalies.filter(a => a.severity === 'MEDIUM').length,
    low: anomalies.filter(a => a.severity === 'LOW').length,
  };

  return { book: slug, summary, anomalies };
}

// Determine which books to inspect
let booksToInspect = slugs;
if (booksToInspect.length === 0) {
  booksToInspect = readdirSync(FIDELITY_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .filter(slug => existsSync(join(FIDELITY_DIR, slug, 'native.json')));
}

const results = [];
for (const slug of booksToInspect) {
  const result = inspectBook(slug);
  if (result) results.push(result);
}

if (jsonOutput) {
  console.log(JSON.stringify(results, null, 2));
} else {
  for (const result of results) {
    console.log(`\n=== ${result.book} ===`);
    console.log(`  HIGH: ${result.summary.high}  MEDIUM: ${result.summary.medium}  LOW: ${result.summary.low}`);

    if (result.anomalies.length === 0) {
      console.log('  No anomalies detected.');
    } else {
      for (const a of result.anomalies) {
        const icon = a.severity === 'HIGH' ? 'X' : a.severity === 'MEDIUM' ? '!' : '-';
        console.log(`  [${icon}] ${a.detector}: ${a.message}`);
      }
    }
  }

  // Write anomaly-report.json for each single-book run
  if (slugs.length === 1 && results.length === 1) {
    const reportPath = join(FIDELITY_DIR, slugs[0], 'anomaly-report.json');
    writeFileSync(reportPath, JSON.stringify(results[0], null, 2) + '\n');
    console.log(`\nReport written to ${reportPath}`);
  }
}

// Exit with error if any HIGH anomalies found
const totalHigh = results.reduce((s, r) => s + r.summary.high, 0);
if (totalHigh > 0) {
  process.exit(1);
}
