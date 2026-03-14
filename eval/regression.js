#!/usr/bin/env node
/**
 * Multi-book regression checker — ensures VeloPDFProcessor changes
 * don't degrade fidelity scores for any book in the test corpus.
 *
 * Compares current scores against locked baselines per book.
 * Fails if any dimension drops more than the allowed tolerance
 * below its baseline.
 *
 * Usage:
 *   node eval/regression.js
 *   node eval/regression.js --tolerance 0.05
 *   node eval/regression.js --lock   # Update baselines to current scores
 *   node eval/regression.js --inspect  # Also run anomaly detection
 */

import { existsSync, readFileSync, writeFileSync, readdirSync } from 'fs';
import { join, resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { scoreFidelity, formatFidelityReport } from './score.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = resolve(__dirname, '..');
const FIDELITY_DIR = join(ROOT, 'corpus');

// Parse args
const args = process.argv.slice(2);
let tolerance = 0.02; // 2% allowed regression per dimension
let lockMode = false;
let inspectMode = false;

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--tolerance': tolerance = parseFloat(args[++i]); break;
    case '--lock': lockMode = true; break;
    case '--inspect': inspectMode = true; break;
  }
}

function findScoredBooks() {
  const dirs = readdirSync(FIDELITY_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);

  const books = [];
  for (const slug of dirs) {
    const bookDir = join(FIDELITY_DIR, slug);
    const hasNative = existsSync(join(bookDir, 'native.json'));
    const hasPredicted = existsSync(join(bookDir, 'predicted.json'));

    if (hasNative && hasPredicted) {
      books.push(slug);
    }
  }
  return books;
}

function scoreBook(slug) {
  const bookDir = join(FIDELITY_DIR, slug);
  const predicted = JSON.parse(readFileSync(join(bookDir, 'predicted.json'), 'utf-8'));
  const native = JSON.parse(readFileSync(join(bookDir, 'native.json'), 'utf-8'));
  return scoreFidelity(predicted, native);
}

function loadBaseline(slug) {
  const baselinePath = join(FIDELITY_DIR, slug, 'baseline.json');
  if (!existsSync(baselinePath)) return null;
  return JSON.parse(readFileSync(baselinePath, 'utf-8'));
}

function saveBaseline(slug, result) {
  const baselinePath = join(FIDELITY_DIR, slug, 'baseline.json');
  const baseline = {
    book: slug,
    locked: new Date().toISOString().split('T')[0],
    overall: result.overall,
    dimensions: {}
  };
  for (const d of result.dimensions) {
    baseline.dimensions[d.name] = d.score;
  }
  writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + '\n');
  return baseline;
}

// Main
const books = findScoredBooks();
if (books.length === 0) {
  console.error('No books found with both native.json and predicted.json');
  process.exit(1);
}

console.error(`\n=== PDF Fidelity Regression Check ===`);
console.error(`Books: ${books.join(', ')}`);
console.error(`Tolerance: ${(tolerance * 100).toFixed(1)}% per dimension\n`);

let allPassed = true;
const results = [];

for (const slug of books) {
  const result = scoreBook(slug);
  console.log(formatFidelityReport(slug, result));

  if (lockMode) {
    const baseline = saveBaseline(slug, result);
    console.error(`  → Baseline locked for ${slug} (overall: ${(baseline.overall * 100).toFixed(1)}%)`);
    results.push({ slug, result, status: 'locked' });
    continue;
  }

  const baseline = loadBaseline(slug);
  if (!baseline) {
    console.error(`  ⚠ No baseline.json for ${slug} — run with --lock to create one`);
    results.push({ slug, result, status: 'no-baseline' });
    continue;
  }

  // Check each dimension against baseline
  let bookPassed = true;
  const regressions = [];

  for (const d of result.dimensions) {
    const baselineScore = baseline.dimensions[d.name];
    if (baselineScore === undefined) continue;

    const delta = d.score - baselineScore;
    if (delta < -tolerance) {
      bookPassed = false;
      regressions.push({
        dimension: d.name,
        baseline: baselineScore,
        current: d.score,
        delta
      });
    }
  }

  // Check overall
  const overallDelta = result.overall - baseline.overall;
  if (overallDelta < -tolerance) {
    bookPassed = false;
  }

  if (!bookPassed) {
    allPassed = false;
    console.error(`  ✗ REGRESSION in ${slug}:`);
    for (const r of regressions) {
      console.error(`    ${r.dimension}: ${(r.baseline * 100).toFixed(1)}% → ${(r.current * 100).toFixed(1)}% (Δ${(r.delta * 100).toFixed(1)}%)`);
    }
    if (overallDelta < -tolerance) {
      console.error(`    overall: ${(baseline.overall * 100).toFixed(1)}% → ${(result.overall * 100).toFixed(1)}% (Δ${(overallDelta * 100).toFixed(1)}%)`);
    }
    results.push({ slug, result, status: 'regression', regressions });
  } else {
    const improvements = result.dimensions
      .filter(d => {
        const b = baseline.dimensions[d.name];
        return b !== undefined && d.score > b + 0.001;
      })
      .map(d => `${d.name}: +${((d.score - baseline.dimensions[d.name]) * 100).toFixed(1)}%`);

    if (improvements.length > 0) {
      console.error(`  ✓ ${slug} passed (improvements: ${improvements.join(', ')})`);
    } else {
      console.error(`  ✓ ${slug} passed`);
    }
    results.push({ slug, result, status: 'passed' });
  }
}

console.error(`\n=== Summary ===`);
const passed = results.filter(r => r.status === 'passed').length;
const regressed = results.filter(r => r.status === 'regression').length;
const noBaseline = results.filter(r => r.status === 'no-baseline').length;
const locked = results.filter(r => r.status === 'locked').length;

if (lockMode) {
  console.error(`Locked baselines for ${locked} book(s)`);
} else {
  console.error(`Passed: ${passed} | Regressions: ${regressed} | No baseline: ${noBaseline}`);
  if (!allPassed) {
    console.error('\nFAILED — fix regressions before merging');
    process.exit(1);
  } else {
    console.error('\nAll books passed regression check');
  }
}

// --inspect: run anomaly detection on all books with native.json
if (inspectMode) {
  console.error(`\n=== Anomaly Detection ===`);
  let inspectFailed = false;

  for (const slug of books) {
    const nativePath = join(FIDELITY_DIR, slug, 'native.json');
    if (!existsSync(nativePath)) continue;

    // Dynamic import of inspect-native.js detectors
    const native = JSON.parse(readFileSync(nativePath, 'utf-8'));

    // Inline lightweight anomaly checks (mirrors inspect-native.js core detectors)
    const anomalies = [];

    // 1. OCR garbage ratio
    let totalChars = 0, garbageChars = 0;
    for (const ch of native.chapters) {
      const text = ch.plainText || '';
      totalChars += text.length;
      garbageChars += text.replace(/[\w\s.,;:!?'"()\-\u2014\u2013\u2018\u2019\u201c\u201d]/g, '').length;
    }
    if (totalChars > 0 && garbageChars / totalChars > 0.05) {
      anomalies.push(`OCR garbage: ${(garbageChars / totalChars * 100).toFixed(1)}%`);
    }

    // 2. Running header leakage
    const chCount = native.chapters.length;
    if (chCount >= 3) {
      const lineCounts = {};
      for (const ch of native.chapters) {
        const lines = (ch.plainText || '').split('\n');
        const seen = new Set();
        for (const line of lines) {
          const t = line.trim();
          if (t.length >= 5 && t.length < 70 && !/[.!?]["')\]]*\s*$/.test(t)) {
            if (!seen.has(t)) { seen.add(t); lineCounts[t] = (lineCounts[t] || 0) + 1; }
          }
        }
      }
      const thresh = Math.max(3, Math.floor(chCount * 0.3));
      for (const [text, count] of Object.entries(lineCounts)) {
        if (count >= thresh) {
          anomalies.push(`Header leak: "${text.slice(0, 50)}" in ${count} chapters`);
        }
      }
    }

    if (anomalies.length > 0) {
      inspectFailed = true;
      console.error(`  X ${slug}: ${anomalies.length} HIGH anomalies`);
      for (const a of anomalies) {
        console.error(`    - ${a}`);
      }
    } else {
      console.error(`  OK ${slug}`);
    }
  }

  if (inspectFailed) {
    console.error('\nFAILED — anomaly detection found HIGH-severity issues');
    process.exit(1);
  } else {
    console.error('\nAll books passed anomaly detection');
  }
}
