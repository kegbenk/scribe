/**
 * Aggregation module — transforms per-page AI annotations into
 * a predicted contentStructure JSON.
 *
 * The output matches the contentStructure schema used by the app:
 * { chapters: [{ title, plainText, paragraphs, footnotes, wordCount, ... }] }
 */

/**
 * Aggregate per-page annotations into a predicted contentStructure.
 *
 * @param {object[]} annotations - Array of per-page annotation objects (sorted by pageNumber)
 * @returns {object} Predicted contentStructure
 */
export function aggregate(annotations) {
  if (!annotations.length) {
    return { chapters: [] };
  }

  // Sort by page number
  const sorted = [...annotations].sort((a, b) => a.pageNumber - b.pageNumber);

  // Phase 1: Identify chapter boundaries
  const chapterStarts = [];
  for (let i = 0; i < sorted.length; i++) {
    const page = sorted[i];
    if (page.isChapterStart) {
      chapterStarts.push({
        index: i,
        pageNumber: page.pageNumber,
        title: page.chapterTitle || `Chapter (page ${page.pageNumber})`
      });
    }
  }

  // If no chapter starts detected, treat entire book as one chapter
  if (chapterStarts.length === 0) {
    chapterStarts.push({
      index: 0,
      pageNumber: sorted[0].pageNumber,
      title: 'Full Text'
    });
  }

  // Phase 2: Build chapters
  const chapters = [];

  for (let c = 0; c < chapterStarts.length; c++) {
    const start = chapterStarts[c];
    const endIndex = c + 1 < chapterStarts.length ? chapterStarts[c + 1].index : sorted.length;
    const chapterPages = sorted.slice(start.index, endIndex);

    const bodyParagraphs = [];
    const footnotes = [];
    const footnoteReferences = [];
    let isBackMatter = false;
    let backMatterType = null;

    for (const page of chapterPages) {
      if (page.isBackMatter) {
        isBackMatter = true;
        backMatterType = backMatterType || page.backMatterType;
      }

      // Collect inline footnote references from body text
      for (const ref of (page.footnoteReferences || [])) {
        footnoteReferences.push({
          number: ref.number,
          nearText: ref.nearText || '',
          column: ref.column || 'full',
          pageNumber: page.pageNumber
        });
      }

      // Get regions sorted by reading order
      const regions = (page.regions || [])
        .filter(r => r.type !== 'running_header' && r.type !== 'page_number')
        .sort((a, b) => (a.readingOrder || 0) - (b.readingOrder || 0));

      for (const region of regions) {
        if (region.type === 'footnote') {
          // Extract footnote number from text if possible
          const fnMatch = region.text?.match(/^(\d+)\s+/);
          footnotes.push({
            number: fnMatch ? parseInt(fnMatch[1]) : footnotes.length + 1,
            text: region.text || ''
          });
        } else if (region.type === 'body' || region.type === 'back_matter') {
          // Split text into paragraphs on double newlines
          const text = region.text || '';
          const paras = text.split(/\n{2,}/).map(p => p.trim()).filter(Boolean);
          bodyParagraphs.push(...(paras.length ? paras : [text]));
        } else if (region.type === 'chapter_title' || region.type === 'heading') {
          // Include headings as paragraphs (they're part of the content flow)
          if (region.text) {
            bodyParagraphs.push(region.text.trim());
          }
        }
        // Skip: front_matter, image (for now)
      }
    }

    // Compute plain text and word count
    const plainText = bodyParagraphs.join('\n\n');
    const wordCount = plainText.split(/\s+/).filter(Boolean).length;

    const chapter = {
      title: start.title,
      plainText,
      paragraphs: bodyParagraphs,
      wordCount,
      startPage: start.pageNumber
    };

    if (footnotes.length > 0) {
      chapter.footnotes = footnotes;
    }
    if (footnoteReferences.length > 0) {
      chapter.footnoteReferences = footnoteReferences;
    }
    if (isBackMatter) {
      chapter.isBackMatter = true;
      chapter.backMatterType = backMatterType;
    }

    chapters.push(chapter);
  }

  return { chapters };
}
