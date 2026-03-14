#!/usr/bin/env node
/**
 * PDF Fidelity AI — Orchestrator
 *
 * Main entry point for the vision-based fidelity testing pipeline.
 *
 * Usage:
 *   # Full run (nightly, cheap)
 *   node vision/orchestrator.js --mode batch
 *
 *   # Fast iteration (dev, specific pages)
 *   node vision/orchestrator.js --mode realtime --books janus-faces --pages 6-20
 *
 *   # Score only (cached predictions exist)
 *   node vision/orchestrator.js --score-only --books all
 */

import { existsSync, readFileSync, writeFileSync, readdirSync, mkdirSync } from 'fs';
import { join, resolve, dirname } from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { fileHash, hasCachedPages, setPageManifest, getPageManifest } from './cache.js';
import { analyzeRealtime, analyzeBatch, retrieveBatchResults } from './analyze.js';
import { aggregate } from '../eval/aggregate.js';
import { scoreFidelity, formatFidelityReport } from '../eval/score.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = resolve(__dirname, '..');
const FIDELITY_DIR = join(ROOT, 'corpus');
const RENDER_SCRIPT = join(__dirname, 'render-pages.swift');

const DEFAULT_DPI = 150;
const DEFAULT_THRESHOLD = 0.90;

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {
    mode: 'realtime',
    books: 'all',
    pages: null,
    scoreOnly: false,
    noCache: false,
    threshold: DEFAULT_THRESHOLD,
    dpi: DEFAULT_DPI,
    batchId: null // For retrieving batch results
  };

  const rawArgs = argv.slice(2);
  for (let i = 0; i < rawArgs.length; i++) {
    switch (rawArgs[i]) {
      case '--mode':
        args.mode = rawArgs[++i];
        break;
      case '--books':
        args.books = rawArgs[++i];
        break;
      case '--pages':
        args.pages = rawArgs[++i];
        break;
      case '--score-only':
        args.scoreOnly = true;
        break;
      case '--no-cache':
        args.noCache = true;
        break;
      case '--threshold':
        args.threshold = parseFloat(rawArgs[++i]);
        break;
      case '--dpi':
        args.dpi = parseInt(rawArgs[++i]);
        break;
      case '--batch-id':
        args.batchId = rawArgs[++i];
        break;
      default:
        console.error(`Unknown argument: ${rawArgs[i]}`);
        process.exit(1);
    }
  }

  return args;
}

function parsePageRange(rangeStr) {
  if (!rangeStr) return null;
  const parts = rangeStr.split('-').map(Number);
  if (parts.length === 2) {
    const pages = [];
    for (let i = parts[0]; i <= parts[1]; i++) pages.push(i);
    return pages;
  }
  return [parts[0]];
}

// ---------------------------------------------------------------------------
// Book discovery
// ---------------------------------------------------------------------------

function discoverBooks(filter) {
  const books = [];
  if (!existsSync(FIDELITY_DIR)) return books;

  for (const entry of readdirSync(FIDELITY_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const slug = entry.name;
    const pdfPath = join(FIDELITY_DIR, slug, 'source.pdf');

    if (!existsSync(pdfPath)) continue;
    if (filter !== 'all' && !filter.split(',').includes(slug)) continue;

    books.push({ slug, dir: join(FIDELITY_DIR, slug), pdfPath });
  }

  return books;
}

// ---------------------------------------------------------------------------
// Pipeline steps
// ---------------------------------------------------------------------------

async function renderPages(book, dpi, noCache) {
  const pagesDir = join(book.dir, 'pages');
  mkdirSync(pagesDir, { recursive: true });

  const pdfH = fileHash(book.pdfPath);

  if (!noCache && hasCachedPages(book.dir, pdfH, dpi)) {
    console.error(`[${book.slug}] Pages cached (pdf hash: ${pdfH.slice(0, 8)})`);
    return getPageManifest(book.dir);
  }

  console.error(`[${book.slug}] Rendering pages at ${dpi} DPI...`);
  const result = execSync(
    `swift "${RENDER_SCRIPT}" "${book.pdfPath}" "${pagesDir}" --dpi ${dpi}`,
    { encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 }
  );

  const manifest = JSON.parse(result);
  setPageManifest(book.dir, pdfH, dpi, manifest);
  return manifest;
}

async function processBook(book, args) {
  console.error(`\n=== ${book.slug} ===`);

  // Step 1: Score-only mode
  if (args.scoreOnly) {
    const predictedPath = join(book.dir, 'predicted.json');
    const nativePath = join(book.dir, 'native.json');

    if (!existsSync(predictedPath)) {
      console.error(`[${book.slug}] No predicted.json — run full pipeline first`);
      return null;
    }
    if (!existsSync(nativePath)) {
      console.error(`[${book.slug}] No native.json — export from VeloPDFProcessor first`);
      return null;
    }

    const predicted = JSON.parse(readFileSync(predictedPath, 'utf-8'));
    const native = JSON.parse(readFileSync(nativePath, 'utf-8'));
    const result = scoreFidelity(predicted, native, args.threshold);
    console.log(formatFidelityReport(book.slug, result));

    writeFileSync(
      join(book.dir, 'fidelity-report.json'),
      JSON.stringify(result, null, 2)
    );

    return result;
  }

  // Step 2: Render pages
  const manifest = await renderPages(book, args.dpi, args.noCache);
  if (!manifest?.pages?.length) {
    console.error(`[${book.slug}] No pages rendered`);
    return null;
  }

  // Step 3: AI analysis
  const pageFilter = parsePageRange(args.pages);
  let annotations;

  if (args.mode === 'batch') {
    if (args.batchId) {
      // Retrieve existing batch results
      const batchData = JSON.parse(readFileSync(join(book.dir, 'batch-pending.json'), 'utf-8'));
      annotations = await retrieveBatchResults(args.batchId, book.dir, batchData.uncachedPages);
    } else {
      const { cached, batchId, uncachedPages } = await analyzeBatch(
        book.dir, manifest.pages, { noCache: args.noCache, pageFilter }
      );

      if (batchId) {
        // Save batch info for later retrieval
        writeFileSync(
          join(book.dir, 'batch-pending.json'),
          JSON.stringify({ batchId, uncachedPages }, null, 2)
        );
        console.error(`[${book.slug}] Batch submitted: ${batchId}`);
        console.error(`  Retrieve later with: --batch-id ${batchId}`);
        return null;
      }

      annotations = cached;
    }
  } else {
    annotations = await analyzeRealtime(
      book.dir, manifest.pages, { noCache: args.noCache, pageFilter }
    );
  }

  if (!annotations?.length) {
    console.error(`[${book.slug}] No annotations produced`);
    return null;
  }

  // Step 4: Aggregate into predicted contentStructure
  const predicted = aggregate(annotations);
  predicted._annotations = annotations; // Attach for running_header/reading_order scoring

  writeFileSync(
    join(book.dir, 'predicted.json'),
    JSON.stringify(predicted, null, 2)
  );
  console.error(`[${book.slug}] Predicted contentStructure: ${predicted.chapters.length} chapters`);

  // Step 5: Score against native if available
  const nativePath = join(book.dir, 'native.json');
  if (existsSync(nativePath)) {
    const native = JSON.parse(readFileSync(nativePath, 'utf-8'));
    const result = scoreFidelity(predicted, native, args.threshold);
    console.log(formatFidelityReport(book.slug, result));

    writeFileSync(
      join(book.dir, 'fidelity-report.json'),
      JSON.stringify(result, null, 2)
    );

    return result;
  } else {
    console.error(`[${book.slug}] No native.json — skipping scoring.`);
    console.error(`  Export from VeloPDFProcessor and place at: ${nativePath}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);

  console.error('=== PDF Fidelity AI ===');
  console.error(`Mode: ${args.mode} | Books: ${args.books} | Threshold: ${args.threshold}`);
  if (args.pages) console.error(`Pages: ${args.pages}`);

  const books = discoverBooks(args.books);

  if (books.length === 0) {
    console.error(`\nNo books found in ${FIDELITY_DIR}`);
    console.error('Place source PDFs at corpus/<slug>/source.pdf');
    process.exit(0);
  }

  console.error(`Found ${books.length} book(s): ${books.map(b => b.slug).join(', ')}`);

  let passed = 0;
  let failed = 0;
  let skipped = 0;

  for (const book of books) {
    try {
      const result = await processBook(book, args);
      if (!result) {
        skipped++;
      } else if (result.pass) {
        passed++;
      } else {
        failed++;
      }
    } catch (err) {
      console.error(`[${book.slug}] Error: ${err.message}`);
      if (err.stack) console.error(err.stack);
      failed++;
    }
  }

  console.error('\n=== Summary ===');
  console.error(`Passed: ${passed} | Failed: ${failed} | Skipped: ${skipped}`);

  if (failed > 0) {
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
