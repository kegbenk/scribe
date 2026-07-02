#!/usr/bin/env node
/**
 * Performance harness — wall-clock latency and peak memory per corpus book.
 *
 * Times a release-build scribe-cli extraction of every book whose source is
 * reachable (corpus/sources.json, same resolution as regenerate.js) and
 * captures peak RSS via /usr/bin/time -l (macOS). Results are printed as a
 * table and written to eval/perf-report.json.
 *
 * Informational, not a regression gate: latency varies across hardware, so
 * numbers are only comparable within one machine. docs/benchmarks.md numbers
 * come from runs of this script.
 *
 * Usage:
 *   swift build -c release --package-path swift
 *   node eval/perf.js                 # all reachable books
 *   node eval/perf.js --book healing-dream
 *   node eval/perf.js --cli ./path/to/scribe-cli
 */

import { existsSync, readFileSync, writeFileSync, statSync } from 'fs';
import { spawnSync } from 'child_process';
import { join, resolve, dirname, isAbsolute } from 'path';
import { homedir, cpus } from 'os';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = resolve(__dirname, '..');

const args = process.argv.slice(2);
let onlyBook = null;
let cliPath = join(ROOT, 'swift', '.build', 'release', 'scribe-cli');

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--book': onlyBook = args[++i]; break;
    case '--cli':  cliPath = resolve(args[++i]); break;
  }
}

if (!existsSync(cliPath)) {
  console.error(`[perf] scribe-cli not found at ${cliPath}`);
  console.error(`[perf] Build it first: swift build -c release --package-path swift`);
  process.exit(2);
}

function loadSources() {
  const userPath = join(ROOT, 'corpus', 'sources.json');
  const examplePath = join(ROOT, 'corpus', 'sources.example.json');
  const path = existsSync(userPath) ? userPath : examplePath;
  return JSON.parse(readFileSync(path, 'utf-8')).books || {};
}

function resolveSourcePath(slug, value) {
  if (!value || slug.startsWith('_')) return null;
  if (value === 'default') {
    const pdf = join(ROOT, 'corpus', slug, 'source.pdf');
    const epub = join(ROOT, 'corpus', slug, 'source.epub');
    return existsSync(pdf) ? pdf : epub;
  }
  let p = value;
  if (p.startsWith('~/')) p = join(homedir(), p.slice(2));
  if (!isAbsolute(p)) p = resolve(ROOT, p);
  return p;
}

function measure(sourcePath) {
  const outPath = '/tmp/scribe-perf-scratch.json';
  const started = Date.now();
  // /usr/bin/time -l reports "maximum resident set size" in bytes on macOS.
  const result = spawnSync('/usr/bin/time', ['-l', cliPath, 'extract', sourcePath, '--output', outPath], {
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const wallMs = Date.now() - started;
  if (result.status !== 0) {
    return { ok: false, error: (result.stderr || '').split('\n')[0] };
  }
  const rssMatch = (result.stderr || '').match(/(\d+)\s+maximum resident set size/);
  const peakRSSMB = rssMatch ? Number(rssMatch[1]) / 1048576 : null;
  const output = JSON.parse(readFileSync(outPath, 'utf-8'));
  return {
    ok: true,
    wallMs,
    peakRSSMB,
    words: output.metadata?.totalWords ?? null,
    chapters: output.chapters?.length ?? null,
  };
}

const sources = loadSources();
const rows = [];

for (const [slug, value] of Object.entries(sources)) {
  if (onlyBook && slug !== onlyBook) continue;
  const sourcePath = resolveSourcePath(slug, value);
  if (!sourcePath || !existsSync(sourcePath)) {
    if (!slug.startsWith('_')) console.error(`  SKIP ${slug}: source not found`);
    continue;
  }
  const sizeMB = statSync(sourcePath).size / 1048576;
  process.stderr.write(`  ${slug} ... `);
  const m = measure(sourcePath);
  if (!m.ok) {
    console.error(`FAIL: ${m.error}`);
    rows.push({ book: slug, error: m.error });
    continue;
  }
  console.error(`${(m.wallMs / 1000).toFixed(2)}s, peak ${m.peakRSSMB?.toFixed(0) ?? '?'} MB`);
  rows.push({
    book: slug,
    sourceMB: Number(sizeMB.toFixed(1)),
    wallSeconds: Number((m.wallMs / 1000).toFixed(2)),
    peakRSSMB: m.peakRSSMB === null ? null : Number(m.peakRSSMB.toFixed(0)),
    words: m.words,
    chapters: m.chapters,
    wordsPerSecond: m.words ? Math.round(m.words / (m.wallMs / 1000)) : null,
  });
}

if (rows.length === 0) {
  console.error('No books measured. Configure corpus/sources.json.');
  process.exit(1);
}

const report = {
  generatedAt: new Date().toISOString(),
  cli: cliPath,
  hardware: cpus()[0]?.model ?? 'unknown',
  books: rows,
};
writeFileSync(join(__dirname, 'perf-report.json'), JSON.stringify(report, null, 2) + '\n');

console.log('\nbook                  size(MB)   wall(s)  peakRSS(MB)     words   words/s');
for (const r of rows) {
  if (r.error) { console.log(`${r.book.padEnd(22)} ERROR: ${r.error}`); continue; }
  console.log(
    r.book.padEnd(22) +
    String(r.sourceMB).padStart(8) +
    String(r.wallSeconds).padStart(10) +
    String(r.peakRSSMB ?? '?').padStart(13) +
    String(r.words ?? '?').padStart(10) +
    String(r.wordsPerSecond ?? '?').padStart(10)
  );
}
console.log(`\n→ eval/perf-report.json`);
