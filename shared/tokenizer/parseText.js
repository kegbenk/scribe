/**
 * Canonical text tokenizer for Scribe.
 * Must produce identical output to ScribeTokenizer.parseText() in Swift.
 */

/**
 * Parse text into an array of words, preserving line break information.
 * Words that follow line breaks are marked with a special prefix.
 * @param {string} text - The input text to parse
 * @returns {string[]} Array of words (paragraph breaks marked with '\n', first word after break prefixed with '\u27E9')
 */
export function parseText(text) {
  if (!text || typeof text !== "string") return [];

  // Split by line breaks first to preserve line structure
  const lines = text.split(/\n/);
  const words = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.length === 0) continue;

    const lineWords = line.split(/\s+/).filter(w => w.length > 0);

    // Insert a blank marker between paragraphs (after the first paragraph)
    if (words.length > 0 && lineWords.length > 0) {
      words.push('\n'); // This will display as blank with a pause

      // Mark the first word of the new paragraph so it displays longer
      if (lineWords.length > 0) {
        lineWords[0] = '\u27E9' + lineWords[0]; // \u27E9 marker for first word after line break
      }
    }

    // Use loop instead of spread operator to avoid stack overflow on large PDFs
    for (let j = 0; j < lineWords.length; j++) {
      words.push(lineWords[j]);
    }
  }

  return words;
}
