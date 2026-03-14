/**
 * Caching layer for PDF fidelity AI pipeline.
 *
 * Three cache levels, all stored under corpus/<slug>/:
 * 1. Page PNGs — keyed by sha256(pdf) + pageIndex + dpi
 * 2. AI annotations — keyed by sha256(png) + model + promptVersion
 * 3. Predicted contentStructure — keyed by sha256(all annotations)
 */

import { createHash } from 'crypto';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

/**
 * SHA-256 hash of a file's contents (first 12 hex chars).
 */
export function fileHash(filePath) {
  const data = readFileSync(filePath);
  return createHash('sha256').update(data).digest('hex').slice(0, 16);
}

/**
 * SHA-256 hash of a string (first 12 hex chars).
 */
export function stringHash(str) {
  return createHash('sha256').update(str).digest('hex').slice(0, 16);
}

/**
 * Check if a cached AI annotation exists for a given page PNG.
 * @param {string} bookDir - Path to corpus/<slug>/
 * @param {string} pngPath - Path to the page PNG
 * @param {string} model - Model ID used for analysis
 * @param {string} promptVersion - Hash of prompt templates
 * @returns {object|null} Cached annotation or null
 */
export function getCachedAnnotation(bookDir, pngPath, model, promptVersion) {
  const cacheDir = join(bookDir, 'ai-annotations');
  const pngHash = fileHash(pngPath);
  const cacheKey = stringHash(`${pngHash}:${model}:${promptVersion}`);
  const cachePath = join(cacheDir, `${cacheKey}.json`);

  if (existsSync(cachePath)) {
    try {
      return JSON.parse(readFileSync(cachePath, 'utf-8'));
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Save an AI annotation to cache.
 */
export function setCachedAnnotation(bookDir, pngPath, model, promptVersion, annotation) {
  const cacheDir = join(bookDir, 'ai-annotations');
  mkdirSync(cacheDir, { recursive: true });
  const pngHash = fileHash(pngPath);
  const cacheKey = stringHash(`${pngHash}:${model}:${promptVersion}`);
  const cachePath = join(cacheDir, `${cacheKey}.json`);
  writeFileSync(cachePath, JSON.stringify(annotation, null, 2));
}

/**
 * Check if page PNGs already exist for a book.
 * @param {string} bookDir - Book directory
 * @param {string} pdfHash - Hash of the source PDF
 * @param {number} dpi - Render DPI
 * @returns {boolean}
 */
export function hasCachedPages(bookDir, pdfHash, dpi) {
  const manifestPath = join(bookDir, 'pages', 'manifest.json');
  if (!existsSync(manifestPath)) return false;
  try {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));
    return manifest.pdfHash === pdfHash && manifest.dpi === dpi;
  } catch {
    return false;
  }
}

/**
 * Save page render manifest.
 */
export function setPageManifest(bookDir, pdfHash, dpi, manifest) {
  const pagesDir = join(bookDir, 'pages');
  mkdirSync(pagesDir, { recursive: true });
  const data = { pdfHash, dpi, ...manifest };
  writeFileSync(join(pagesDir, 'manifest.json'), JSON.stringify(data, null, 2));
}

/**
 * Read page render manifest.
 */
export function getPageManifest(bookDir) {
  const manifestPath = join(bookDir, 'pages', 'manifest.json');
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf-8'));
  } catch {
    return null;
  }
}
