#!/usr/bin/env node
/**
 * Convert Marker JSON output to Velo contentStructure format.
 *
 * Marker handles the ML work: block classification, footnote detection,
 * header removal, reading order. This converter maps its output to
 * Velo's contentStructure format.
 *
 * Chapter boundary detection uses heading-level + title patterns because
 * h2 is used for both chapters and subsections in most books. This is
 * structural grouping of Marker's clean output — NOT text extraction
 * heuristics like VeloPDFProcessor.
 *
 * Usage: node converters/marker-to-content-structure.js <marker-json> <output-json>
 */

import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';

// --- Text extraction from Marker blocks ---

function decodeEntities(text) {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n)))
    .replace(/&nbsp;/g, ' ');
}

function stripHtml(html) {
  // Strip real tags, decode entities, strip any tags that emerged from entities
  return decodeEntities(html.replace(/<[^>]+>/g, '')).replace(/<[^>]+>/g, '');
}

function extractText(block) {
  if (block.html) return stripHtml(block.html).trim();
  if (block.children) {
    return block.children.map(c => extractText(c)).filter(Boolean).join(' ').trim();
  }
  if (block.text) return decodeEntities(block.text).trim();
  return '';
}

function getHeadingLevel(block) {
  if (block.html) {
    const match = block.html.match(/<h(\d)/i);
    if (match) return parseInt(match[1]);
  }
  if (block.children) {
    for (const child of block.children) {
      const level = getHeadingLevel(child);
      if (level) return level;
    }
  }
  return null;
}

// --- HTML preservation for rich rendering ---

function cleanBlockHtml(block) {
  // Build clean HTML from Marker block, preserving semantic tags
  const html = block.html || '';
  if (!html) {
    // Build from children
    if (block.children) {
      return block.children.map(c => cleanBlockHtml(c)).filter(Boolean).join('');
    }
    return '';
  }
  // Remove Marker-internal attributes but keep semantic HTML
  return html
    .replace(/\s*block-type="[^"]*"/g, '')
    .replace(/\s*block-type='[^']*'/g, '')
    .replace(/<content-ref[^>]*><\/content-ref>/g, '')
    .replace(/<content-ref[^>]*\/>/g, '');
}

// --- Chapter boundary detection ---

function isAllCaps(text) {
  return /^[\u201C\u201D"A-Z][A-Z\s\u201C\u201D"',.\-\u2014:?!()]+$/.test(text);
}

function isFullyItalic(html) {
  if (!html) return false;
  const inner = html.replace(/<\/?h\d[^>]*>/gi, '').trim();
  if (!inner) return false;
  const totalText = stripHtml(inner).trim();
  if (!totalText || totalText.length < 3) return false;
  // Strip italic content; if less than 40% of text remains, it's predominantly italic
  const withoutItalic = inner.replace(/<i[^>]*>[\s\S]*?<\/i>/gi, '');
  const remainingText = stripHtml(withoutItalic).trim();
  return remainingText.length / totalText.length < 0.4;
}

function isChapterMatch(text, level, html) {
  if (/^\d+\.\d+\s/.test(text)) return false;
  if (/^CHAPTER\s/i.test(text)) return 'chapter-keyword';
  if (level <= 1 && text.length > 5 && !/^\(/.test(text) && isAllCaps(text)) return 'h1';
  if (/^(INTRODUCTION|PREFACE|PROLOGUE|EPILOGUE|APPENDIX|NOTES|INDEX|CONTENTS)/i.test(text)) return 'named-section';
  if (level <= 2 && /^\d+[.\s]\s*[A-Z]/.test(text) && !/^\d+\.\d+/.test(text)) return 'numbered-chapter';
  if (/^(LIST OF|TABLE OF|COMMISSION)/i.test(text)) return 'special-section';
  if (level <= 2 && isAllCaps(text) && text.length > 5) return 'allcaps-h2';
  if (isFullyItalic(html) && text.length > 5) return 'italic-title';
  return false;
}

// --- Main conversion ---

function convert(markerJson) {
  const pages = markerJson.children || [];

  // Collect all blocks with page info and raw HTML
  const allBlocks = [];
  for (let pi = 0; pi < pages.length; pi++) {
    const page = pages[pi];
    if (!page.children) continue;
    for (const block of page.children) {
      allBlocks.push({
        page: pi,
        type: block.block_type || '?',
        text: extractText(block),
        html: cleanBlockHtml(block),
        headingLevel: block.block_type === 'SectionHeader' ? getHeadingLevel(block) : null,
      });
    }
  }

  // Reclassify Text blocks that are actually footnotes (Marker sometimes misses these)
  // Pattern: starts with "25. Author Name, Title..." — numbered citation
  for (const block of allBlocks) {
    if (block.type === 'Text' && /^\d{1,3}\.\s+[A-Z]/.test(block.text) && block.text.length > 50) {
      block.type = 'Footnote';
    }
  }

  // Identify TOC pages
  const tocPages = new Set();
  for (const block of allBlocks) {
    if (block.type === 'TableOfContents') tocPages.add(block.page);
  }
  for (const p of [...tocPages]) {
    const nextBlocks = allBlocks.filter(b => b.page === p + 1);
    const headers = nextBlocks.filter(b => b.type === 'SectionHeader').length;
    const texts = nextBlocks.filter(b => b.type === 'Text').length;
    if (headers > 3 && texts <= headers) tocPages.add(p + 1);
  }

  // Find chapter boundaries
  const sectionHeaders = allBlocks.filter(b => b.type === 'SectionHeader');
  const chapterStarts = [];
  const usedIndices = new Set();

  for (let i = 0; i < sectionHeaders.length; i++) {
    if (usedIndices.has(i)) continue;
    const header = sectionHeaders[i];
    const text = header.text.trim();
    if (!text) continue;
    if (tocPages.has(header.page)) continue;

    const headersOnPage = sectionHeaders.filter(h => h.page === header.page).length;
    if (headersOnPage > 8) continue;

    const level = header.headingLevel || 2;
    const matchType = isChapterMatch(text, level, header.html);
    if (!matchType) continue;

    // Merge subtitle on same page (only if both are same style, e.g., both italic or both allcaps)
    let title = text;
    for (let j = i + 1; j < sectionHeaders.length; j++) {
      const next = sectionHeaders[j];
      if (next.page !== header.page) break;
      const nextText = next.text.trim();
      if (!nextText) continue;
      const nextMatch = isChapterMatch(nextText, next.headingLevel || 2, next.html);
      if (nextMatch && nextMatch !== 'allcaps-h2' && nextMatch !== 'h1') break;
      // Only merge if both headings share the same style (e.g., both italic)
      if (matchType === 'italic-title' && !isFullyItalic(next.html)) break;
      if (isAllCaps(nextText) || /^[A-Z]/.test(nextText)) {
        title += ' ' + nextText;
        usedIndices.add(j);
      }
      break;
    }

    chapterStarts.push({ page: header.page, title, level });
  }

  // Deduplicate same-page chapter starts (e.g., italic chapter title + "Introduction" sub-section)
  for (let i = chapterStarts.length - 1; i > 0; i--) {
    if (chapterStarts[i].page === chapterStarts[i - 1].page) {
      chapterStarts.splice(i, 1);
    }
  }

  if (chapterStarts.length === 0) {
    chapterStarts.push({ page: 0, title: 'Full Text', level: 1 });
  }

  // Build chapters — trust Marker's block classification for content
  const chapters = [];
  for (let ci = 0; ci < chapterStarts.length; ci++) {
    const start = chapterStarts[ci];
    const endPage = chapterStarts[ci + 1]
      ? chapterStarts[ci + 1].page - 1
      : pages.length - 1;

    const bodyParagraphs = [];
    const bodyHtml = [];
    const footnotes = [];
    const footnoteHtml = [];

    for (const block of allBlocks) {
      if (block.page < start.page || block.page > endPage) continue;
      if (!block.text.trim() && !block.html.trim()) continue;

      // Skip chapter headers on start page
      if (block.page === start.page && block.type === 'SectionHeader') continue;

      switch (block.type) {
        case 'Footnote': {
          const fnText = block.text.trim();
          footnotes.push(fnText);
          const fnNumMatch = fnText.match(/^(\d+)\.\s/);
          const fnNum = fnNumMatch ? fnNumMatch[1] : null;
          if (block.html) {
            const fnId = fnNum ? ` id="fn-${fnNum}"` : '';
            // Replace leading number with an anchor link so tapping scrolls back to top
            let fnHtmlContent = block.html;
            if (fnNum) {
              // Turn "25. Text..." into linked "25. Text... ↩"
              fnHtmlContent = fnHtmlContent.replace(
                new RegExp(`(>\\s*(?:<[^>]+>\\s*)*)${fnNum}\\.\\s`),
                `$1<a href="#fn-top" class="fn-num">${fnNum}.</a> `
              );
            }
            footnoteHtml.push(`<div class="footnote"${fnId}>${fnHtmlContent}</div>`);
          }
          break;
        }
        case 'PageHeader':
        case 'PageFooter':
        case 'TableOfContents':
          break;
        case 'SectionHeader': {
          // Subsection headers in body
          const level = block.headingLevel || 3;
          bodyParagraphs.push(block.text.trim());
          bodyHtml.push(`<h${level}>${stripHtml(block.html || block.text)}</h${level}>`);
          break;
        }
        case 'ListGroup':
          bodyParagraphs.push(block.text.trim());
          bodyHtml.push(block.html || `<p>${stripHtml(block.text)}</p>`);
          break;
        default:
          bodyParagraphs.push(block.text.trim());
          bodyHtml.push(block.html || `<p>${stripHtml(block.text)}</p>`);
      }
    }

    // Build plainText with footnotes at end
    let plainText = bodyParagraphs.join('\n\n');
    if (footnotes.length > 0) {
      plainText += '\n\n———\n\n' + footnotes.join('\n\n');
    }

    let htmlContent = '<div id="fn-top"></div>\n' + bodyHtml.join('\n');
    if (footnoteHtml.length > 0) {
      htmlContent += '\n<hr class="footnote-divider">\n<section class="footnotes">\n' +
        '<h4 class="footnotes-header">Footnotes</h4>\n' +
        footnoteHtml.join('\n') + '\n</section>';
    }

    const wordCount = plainText.split(/\s+/).filter(Boolean).length;

    const title = cleanTitle(start.title);
    const isBackMatter = /^(appendix|notes|index|bibliography|glossary)/i.test(title);

    chapters.push({
      title,
      startPage: start.page,
      wordCount,
      plainText,
      htmlContent,
      footnotes: footnotes.map((text, i) => ({ number: i + 1, text })),
      images: [],
      isBackMatter,
      sourceType: 'marker'
    });
  }

  return {
    chapters,
    metadata: {
      source: 'marker-pdf',
      version: '1.10.2',
      totalPages: pages.length,
      totalChapters: chapters.length,
      totalWords: chapters.reduce((sum, ch) => sum + ch.wordCount, 0),
      generatedAt: new Date().toISOString()
    }
  };
}

function cleanTitle(title) {
  return title.replace(/\s+/g, ' ').replace(/^\d+[.\s]\s*/, '').trim();
}

// CLI
const args = process.argv.slice(2);
if (args.length < 2) {
  console.error('Usage: node marker-to-content-structure.js <marker-json> <output-json>');
  process.exit(1);
}

const [inputPath, outputPath] = args;
const markerJson = JSON.parse(readFileSync(inputPath, 'utf-8'));

console.log(`Converting ${inputPath}...`);
const contentStructure = convert(markerJson);

console.log(`Chapters: ${contentStructure.chapters.length}`);
for (const ch of contentStructure.chapters) {
  const fnCount = ch.footnotes.length;
  const fnMarker = fnCount > 0 ? ` (${fnCount} fn)` : '';
  const bmMarker = ch.isBackMatter ? ' [back matter]' : '';
  console.log(`  "${ch.title}" — ${ch.wordCount} words, p${ch.startPage}${fnMarker}${bmMarker}`);
}
console.log(`Total words: ${contentStructure.metadata.totalWords}`);

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, JSON.stringify(contentStructure, null, 2));
console.log(`Written to ${outputPath}`);
