#!/usr/bin/env python3
"""Ground-truth generator for the pride-prejudice EPUB corpus book.

Unlike PDF books (hand-annotated), an EPUB's chapter structure is declared by
the book itself: NCX navPoints define the chapters, fragment anchors define
their boundaries. This script derives native.json from that declared
structure using only the Python standard library — an implementation
independent of the Swift extraction path.

It encodes the IDEAL semantics: a chapter's text runs from its anchor to the
next navPoint's anchor, across spine-file boundaries. The Swift implementation
currently cuts at file boundaries (spillover text lands in the next chapter),
so the fidelity score honestly reflects that gap rather than papering over it.

Regenerate: python3 corpus/pride-prejudice/annotate.py
"""
import json
import os
import re
import zipfile
from datetime import datetime, timezone
from html.parser import HTMLParser
from xml.etree import ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
EPUB = os.path.join(HERE, 'source.epub')
OUT = os.path.join(HERE, 'native.json')

BLOCK = {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote',
         'tr', 'section', 'article', 'aside', 'figure', 'figcaption',
         'dt', 'dd', 'pre', 'hr', 'br', 'table', 'ul', 'ol'}
SKIP = {'script', 'style', 'head', 'title', 'template'}


class TextExtractor(HTMLParser):
    """Paragraphs + anchor(id) -> paragraph-boundary index."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.paragraphs = []
        self.current = []
        self.skip_depth = 0
        self.anchors = {}

    def flush(self):
        text = ' '.join(''.join(self.current).split())
        self.current = []
        if text:
            self.paragraphs.append(text)

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag in BLOCK:
            self.flush()
        a = dict(attrs)
        anchor = a.get('id') or (a.get('name') if tag == 'a' else None)
        if anchor and anchor not in self.anchors:
            self.anchors[anchor] = len(self.paragraphs)

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip_depth = max(0, self.skip_depth - 1)
            return
        if self.skip_depth:
            return
        if tag in BLOCK:
            self.flush()

    def handle_data(self, data):
        if not self.skip_depth:
            self.current.append(data)


def strip_ns(tag):
    return tag.rsplit('}', 1)[-1]


def main():
    z = zipfile.ZipFile(EPUB)

    container = ET.fromstring(z.read('META-INF/container.xml'))
    opf_path = next(el.get('full-path') for el in container.iter()
                    if strip_ns(el.tag) == 'rootfile')
    opf_dir = os.path.dirname(opf_path)
    opf = ET.fromstring(z.read(opf_path))

    manifest = {}
    ncx_href = None
    for el in opf.iter():
        if strip_ns(el.tag) == 'item':
            manifest[el.get('id')] = (el.get('href'), el.get('media-type'))
            if el.get('media-type') == 'application/x-dtbncx+xml':
                ncx_href = el.get('href')
    spine = [el.get('idref') for el in opf.iter() if strip_ns(el.tag) == 'itemref']

    # navPoints in document order: (label, src)
    ncx = ET.fromstring(z.read(os.path.join(opf_dir, ncx_href)))
    nav_points = []
    for np in ncx.iter():
        if strip_ns(np.tag) != 'navPoint':
            continue
        label = ' '.join(''.join(t.itertext()) for t in np
                         if strip_ns(t.tag) == 'navLabel').split()
        label = ' '.join(label)
        content = next((c for c in np if strip_ns(c.tag) == 'content'), None)
        if label and content is not None:
            nav_points.append((label, content.get('src')))

    # Extract every spine document once; build a global paragraph stream.
    global_paragraphs = []
    anchor_global = {}       # "file#frag" -> global paragraph boundary
    file_start = {}          # file href -> (global boundary, 1-based spine ordinal)
    ordinal = 0
    for idref in spine:
        href, media = manifest[idref]
        if 'html' not in (media or ''):
            continue
        ordinal += 1
        ex = TextExtractor()
        ex.feed(z.read(os.path.join(opf_dir, href)).decode('utf-8', 'replace'))
        ex.flush()
        base = len(global_paragraphs)
        file_start[href] = (base, ordinal)
        for frag, idx in ex.anchors.items():
            anchor_global[f'{href}#{frag}'] = base + idx
        global_paragraphs.extend(ex.paragraphs)

    # Chapter k: from its anchor to navPoint k+1's anchor, across files.
    cuts = []
    for label, src in nav_points:
        href, _, frag = src.partition('#')
        if href not in file_start:
            continue
        boundary = anchor_global.get(f'{href}#{frag}') if frag else file_start[href][0]
        if boundary is None:
            continue
        cuts.append((label, boundary, file_start[href][1]))

    chapters = []
    for i, (label, start, ordinal) in enumerate(cuts):
        end = cuts[i + 1][1] if i + 1 < len(cuts) else len(global_paragraphs)
        if start > end:
            continue
        text = '\n\n'.join(global_paragraphs[start:end])
        chapters.append({
            'title': label,
            'plainText': text,
            'startPage': ordinal,
            'wordCount': len(text.split()),
            'footnotes': [],
            'images': [],
        })

    # Text before the first navPoint anchor (Gutenberg boilerplate header)
    # is front matter the ideal extraction would also surface.
    if cuts and cuts[0][1] > 0:
        text = '\n\n'.join(global_paragraphs[:cuts[0][1]])
        chapters.insert(0, {
            'title': 'Front Matter',
            'plainText': text,
            'startPage': 1,
            'wordCount': len(text.split()),
            'footnotes': [],
            'images': [],
        })

    with open(OUT, 'w') as f:
        json.dump({
            'source': 'source.epub',
            'exportedAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'annotation': 'derived from the EPUB\'s declared NCX/spine structure by annotate.py',
            'chapters': chapters,
        }, f, indent=2, ensure_ascii=False)
    print(f'wrote {OUT}: {len(chapters)} chapters, '
          f'{sum(c["wordCount"] for c in chapters)} words')


if __name__ == '__main__':
    main()
