/**
 * Two-pass per-page analysis using MLX vision.
 *
 * Pass 1 (triage): Quick classification of every page (~27s each, 512 tokens).
 *   Identifies chapter starts, footnotes, back matter, two-column layout.
 *
 * Pass 2 (detail): Full analysis of "interesting" pages only (~108s each, 2048 tokens).
 *   Extracts regions, reading order, footnote references, text excerpts.
 *
 * Boring pages (plain body text) get triage-level annotations with empty regions,
 * which is identical to what fallbackAnnotation() produces — aggregate/score handle
 * them naturally.
 */

import { existsSync } from 'fs';
import { join } from 'path';
import { mlxVision, parseModelJSON, getAvailableMemoryGB, checkMemoryOrDie } from './mlx.js';
import { triagePrompt, detailPrompt, triagePromptHash, detailPromptHash } from './prompts.js';
import { getCachedAnnotation, setCachedAnnotation } from './cache.js';

// Check memory every N pages during batch processing
const MEMORY_CHECK_INTERVAL = 10;

const TRIAGE_MODEL_KEY = 'mlx-qwen2.5vl-7b-4bit-triage';
const DETAIL_MODEL_KEY = 'mlx-qwen2.5vl-7b-4bit-detail';

function fallbackAnnotation(pageNumber) {
  return {
    pageNumber,
    layout: 'single_column',
    isChapterStart: false,
    chapterTitle: null,
    isBackMatter: false,
    backMatterType: null,
    hasFootnotes: false,
    footnoteNumbers: [],
    footnoteReferences: [],
    regions: [],
    _skipped: true
  };
}

function isInteresting(triage) {
  return (
    triage.isChapterStart ||
    triage.hasFootnotes ||
    triage.isBackMatter ||
    triage.layout === 'two_column'
  );
}

/**
 * Build prompt options from toc/bookMeta for the prompt functions.
 */
function promptOpts(toc, bookMeta) {
  const opts = {};
  if (bookMeta?.title) opts.bookTitle = bookMeta.title;
  if (bookMeta?.author) opts.bookAuthor = bookMeta.author;
  if (toc?.found && toc.entries?.length) opts.tocEntries = toc.entries;
  return opts;
}

/**
 * Run a single pass over a set of pages.
 *
 * @param {string} bookDir
 * @param {string} pagesDir
 * @param {Array<{pageNumber: number, file: string}>} pages
 * @param {object} passOpts
 * @param {string} passOpts.label - "triage" or "detail" for logging
 * @param {string} passOpts.cacheModel - Cache model key
 * @param {string} passOpts.pHash - Prompt hash for cache
 * @param {Function} passOpts.promptFn - (pageNumber) => prompt string
 * @param {number} passOpts.maxTokens
 * @param {number} passOpts.timeout
 * @param {boolean} passOpts.noCache
 * @returns {Promise<Map<number, object>>} pageNumber -> annotation
 */
async function runPass(bookDir, pagesDir, pages, passOpts) {
  const { label, cacheModel, pHash, promptFn, maxTokens, timeout, noCache } = passOpts;
  const results = new Map();
  let completed = 0;
  let cached = 0;
  let errors = 0;
  const startTime = Date.now();

  for (const page of pages) {
    const pngPath = join(pagesDir, page.file);

    // Check cache
    if (!noCache && existsSync(pngPath)) {
      const cachedAnn = getCachedAnnotation(bookDir, pngPath, cacheModel, pHash);
      if (cachedAnn) {
        results.set(page.pageNumber, cachedAnn);
        completed++;
        cached++;
        if (completed % 20 === 0 || completed === pages.length) {
          console.error(`    [${label}] [cached] ${completed}/${pages.length}`);
        }
        continue;
      }
    }

    if (!existsSync(pngPath)) {
      results.set(page.pageNumber, fallbackAnnotation(page.pageNumber));
      completed++;
      continue;
    }

    const prompt = promptFn(page.pageNumber);

    try {
      const response = await mlxVision(pngPath, prompt, {
        maxTokens,
        temperature: 0.1,
        timeout
      });

      let annotation;
      try {
        const parsed = parseModelJSON(response);
        annotation = Array.isArray(parsed) ? parsed[0] : parsed;
      } catch (parseErr) {
        console.error(`    [${label}] page ${page.pageNumber}: JSON parse error - ${parseErr.message?.slice(0, 60)}`);
        annotation = fallbackAnnotation(page.pageNumber);
        annotation._parseError = true;
        errors++;
      }

      annotation.pageNumber = page.pageNumber;

      // Normalize arrays
      if (!annotation.regions) annotation.regions = [];
      if (!annotation.footnoteReferences) annotation.footnoteReferences = [];
      if (!annotation.footnoteNumbers) annotation.footnoteNumbers = [];

      setCachedAnnotation(bookDir, pngPath, cacheModel, pHash, annotation);
      results.set(page.pageNumber, annotation);
    } catch (err) {
      console.error(`    [${label}] page ${page.pageNumber}: ${err.message?.slice(0, 100)}`);
      results.set(page.pageNumber, fallbackAnnotation(page.pageNumber));
      errors++;
    }

    completed++;
    if (completed % 5 === 0 || completed === pages.length) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      const analyzed = completed - cached;
      const rate = analyzed > 0 ? (analyzed / ((Date.now() - startTime) / 1000)).toFixed(2) : '0.00';
      const memGB = getAvailableMemoryGB();
      const memStr = memGB !== null ? `, ${memGB.toFixed(1)}GB free` : '';
      console.error(`    [${label}] ${completed}/${pages.length} (${elapsed}s, ${rate} new/s, ${errors} errors${memStr})`);
    }

    // Periodic memory safety check — abort before OOM crashes the system
    if (completed % MEMORY_CHECK_INTERVAL === 0) {
      checkMemoryOrDie(`${label} page ${page.pageNumber}`);
    }
  }

  return results;
}

/**
 * Two-pass analysis of pages using local MLX vision model.
 *
 * @param {string} bookDir - Path to corpus/<slug>/
 * @param {Array<{pageNumber: number, file: string}>} pages - Page manifest
 * @param {object} [opts]
 * @param {object} [opts.toc] - TOC extraction result
 * @param {object} [opts.bookMeta] - Book metadata from book.json
 * @param {boolean} [opts.noCache] - Skip annotation cache
 * @param {number[]} [opts.pageFilter] - Only analyze these page numbers
 * @param {boolean} [opts.noTriage] - Skip triage, run detail on all pages
 * @param {boolean} [opts.detailAll] - Run detail on all pages (still runs triage first)
 * @returns {Promise<object[]>} Per-page annotations
 */
export async function analyzeMLX(bookDir, pages, opts = {}) {
  const pagesDir = join(bookDir, 'pages');
  const pOpts = promptOpts(opts.toc, opts.bookMeta);

  let targetPages = pages;
  if (opts.pageFilter?.length) {
    targetPages = pages.filter(p => opts.pageFilter.includes(p.pageNumber));
  }

  const mode = opts.noTriage ? 'single-pass (detail all)' : 'two-pass';
  console.error(`  Analyzing ${targetPages.length} pages (model: MLX qwen2.5vl-7b-4bit, mode: ${mode})`);

  // --- Single-pass mode (--no-triage): detail every page ---
  if (opts.noTriage) {
    const detailResults = await runPass(bookDir, pagesDir, targetPages, {
      label: 'detail',
      cacheModel: DETAIL_MODEL_KEY,
      pHash: detailPromptHash(),
      promptFn: (pn) => detailPrompt(pn, pOpts),
      maxTokens: 2048,
      timeout: 300000,
      noCache: opts.noCache
    });

    const annotations = targetPages.map(p => detailResults.get(p.pageNumber));
    annotations.sort((a, b) => a.pageNumber - b.pageNumber);
    return annotations;
  }

  // --- Two-pass mode ---

  // Pass 1: Triage (all pages)
  console.error(`\n  --- Pass 1: Triage (${targetPages.length} pages, 512 tokens) ---`);
  const triageResults = await runPass(bookDir, pagesDir, targetPages, {
    label: 'triage',
    cacheModel: TRIAGE_MODEL_KEY,
    pHash: triagePromptHash(),
    promptFn: (pn) => triagePrompt(pn, pOpts),
    maxTokens: 512,
    timeout: 90000,
    noCache: opts.noCache
  });

  // Classify interesting pages
  const interestingPageNums = new Set();
  for (const [pageNum, ann] of triageResults) {
    if (isInteresting(ann) || opts.detailAll) {
      interestingPageNums.add(pageNum);
    }
  }

  const interestingPages = targetPages.filter(p => interestingPageNums.has(p.pageNumber));
  const pct = ((interestingPages.length / targetPages.length) * 100).toFixed(0);
  console.error(`\n  Triage: ${interestingPages.length}/${targetPages.length} pages interesting (${pct}%)`);

  // Pass 2: Detail (interesting pages only)
  let detailResults = new Map();
  if (interestingPages.length > 0) {
    console.error(`  --- Pass 2: Detail (${interestingPages.length} pages, 2048 tokens) ---`);
    detailResults = await runPass(bookDir, pagesDir, interestingPages, {
      label: 'detail',
      cacheModel: DETAIL_MODEL_KEY,
      pHash: detailPromptHash(),
      promptFn: (pn) => detailPrompt(pn, pOpts),
      maxTokens: 2048,
      timeout: 300000,
      noCache: opts.noCache
    });
  }

  // Merge: detail results override triage for interesting pages
  const annotations = [];
  for (const page of targetPages) {
    const detail = detailResults.get(page.pageNumber);
    if (detail) {
      annotations.push(detail);
    } else {
      // Promote triage annotation — add empty arrays for downstream compat
      const triage = triageResults.get(page.pageNumber) || fallbackAnnotation(page.pageNumber);
      if (!triage.footnoteNumbers) triage.footnoteNumbers = [];
      if (!triage.footnoteReferences) triage.footnoteReferences = [];
      if (!triage.regions) triage.regions = [];
      annotations.push(triage);
    }
  }

  annotations.sort((a, b) => a.pageNumber - b.pageNumber);
  return annotations;
}
