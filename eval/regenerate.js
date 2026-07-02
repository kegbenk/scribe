#!/usr/bin/env node
/**
 * Re-generates corpus/<book>/predicted.json from current scribe-cli for each
 * book whose source PDF is reachable, then runs the regression scorer.
 *
 * Reads corpus/sources.json (gitignored, user-specific) to find each book's
 * source PDF. Falls back to corpus/sources.example.json if sources.json is
 * missing. Books whose source is missing on disk are skipped with a warning.
 *
 * Source PDFs are not tracked in this repo. Point corpus/sources.json at
 * paths on your local disk or external drive — see corpus/sources.example.json.
 *
 * Usage:
 *   node eval/regenerate.js                # regen all books with present sources
 *   node eval/regenerate.js --book healing-dream
 *   node eval/regenerate.js --lock         # also re-lock baselines after regen
 *   node eval/regenerate.js --cli ./path/to/scribe-cli
 */

import { existsSync, readFileSync, writeFileSync } from 'fs';
import { spawnSync } from 'child_process';
import { join, resolve, dirname, isAbsolute } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = resolve(__dirname, '..');

const args = process.argv.slice(2);
let onlyBook = null;
let lockMode = false;
let cliPath = join(ROOT, 'swift', '.build', 'debug', 'scribe-cli');

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--book': onlyBook = args[++i]; break;
    case '--lock': lockMode = true; break;
    case '--cli':  cliPath = resolve(args[++i]); break;
  }
}

function loadSources() {
  const userPath = join(ROOT, 'corpus', 'sources.json');
  const examplePath = join(ROOT, 'corpus', 'sources.example.json');
  const path = existsSync(userPath) ? userPath : examplePath;
  if (path === examplePath) {
    console.error(`[regenerate] No corpus/sources.json found; using sources.example.json (defaults only).`);
    console.error(`[regenerate] Copy it to corpus/sources.json and edit to point at your local PDFs.`);
  }
  const data = JSON.parse(readFileSync(path, 'utf-8'));
  return data.books || {};
}

function resolvePdfPath(slug, value) {
  if (!value) return null;
  if (value === 'default') {
    // A book's default source may be a PDF or an EPUB.
    const pdf = join(ROOT, 'corpus', slug, 'source.pdf');
    const epub = join(ROOT, 'corpus', slug, 'source.epub');
    return existsSync(pdf) ? pdf : epub;
  }
  let p = value;
  if (p.startsWith('~/')) p = join(homedir(), p.slice(2));
  if (!isAbsolute(p)) p = resolve(ROOT, p);
  return p;
}

function runScribe(pdfPath, outPath) {
  const result = spawnSync(cliPath, ['extract', pdfPath, '--output', outPath], {
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.status !== 0) {
    return { ok: false, error: result.stderr || `scribe-cli exited ${result.status}` };
  }
  return { ok: true };
}

if (!existsSync(cliPath)) {
  console.error(`[regenerate] scribe-cli not found at ${cliPath}`);
  console.error(`[regenerate] Build it first: (cd swift && swift build)`);
  process.exit(2);
}

const sources = loadSources();
const slugs = Object.keys(sources).filter(s => !s.startsWith('_'));

console.error(`\n=== Regenerating predicted.json ===`);
console.error(`scribe-cli: ${cliPath}`);
console.error(`books: ${onlyBook ? onlyBook : slugs.join(', ')}\n`);

let regenerated = 0;
let skipped = 0;
let failed = 0;
const failures = [];

for (const slug of slugs) {
  if (onlyBook && slug !== onlyBook) continue;
  const pdfPath = resolvePdfPath(slug, sources[slug]);
  if (!pdfPath || !existsSync(pdfPath)) {
    console.error(`  SKIP ${slug}: source not found (${pdfPath || 'no path configured'})`);
    skipped++;
    continue;
  }
  const outPath = join(ROOT, 'corpus', slug, 'predicted.json');
  const result = runScribe(pdfPath, outPath);
  if (result.ok) {
    console.error(`  OK   ${slug}`);
    regenerated++;
  } else {
    console.error(`  FAIL ${slug}: ${result.error.split('\n')[0]}`);
    failures.push({ slug, error: result.error });
    failed++;
  }
}

console.error(`\nRegenerated: ${regenerated} | Skipped: ${skipped} | Failed: ${failed}`);

if (skipped > 0) {
  console.error(`\nTo regenerate skipped books, edit corpus/sources.json with their source PDF paths.`);
  console.error(`See corpus/sources.example.json for the format.`);
}

if (failed > 0) {
  console.error(`\nFailures:`);
  for (const f of failures) {
    console.error(`  --- ${f.slug} ---`);
    console.error(f.error);
  }
  process.exit(1);
}

if (lockMode) {
  console.error(`\n=== Re-locking baselines ===`);
  const regression = spawnSync('node', [join(__dirname, 'regression.js'), '--lock'], {
    stdio: 'inherit',
  });
  process.exit(regression.status || 0);
}
