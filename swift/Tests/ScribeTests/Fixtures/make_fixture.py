#!/usr/bin/env python3
"""Regenerates sample.epub. Run from anywhere: python3 make_fixture.py"""
import zipfile, base64, os

png = base64.b64decode(
"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

container = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''

opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="uid">
  <metadata>
    <dc:identifier id="uid">urn:uuid:scribe-test-0001</dc:identifier>
    <dc:title>The Scribe Test Book</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover-img" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="fig1" href="images/fig1.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="cover"/>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
  </spine>
</package>'''

nav = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body>
<nav epub:type="toc">
<h1>Contents</h1>
<ol>
  <li><a href="ch1.xhtml">Chapter One</a></li>
  <li><a href="ch2.xhtml">Chapter Two</a>
    <ol><li><a href="ch2.xhtml#sec2">A Nested Section</a></li></ol>
  </li>
  <li><a href="ch3.xhtml#c3">Chapter Three</a></li>
</ol>
</nav>
</body>
</html>'''

ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:uuid:scribe-test-0001"/></head>
<docTitle><text>The Scribe Test Book</text></docTitle>
<navMap>
  <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="ch1.xhtml"/></navPoint>
  <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="ch2.xhtml"/>
    <navPoint id="n3" playOrder="3"><navLabel><text>A Nested Section</text></navLabel><content src="ch2.xhtml#sec2"/></navPoint>
  </navPoint>
  <navPoint id="n4" playOrder="4"><navLabel><text>Chapter Three</text></navLabel><content src="ch3.xhtml#c3"/></navPoint>
</navMap>
</ncx>'''

cover = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Cover</title></head>
<body><div><img src="images/fig1.png" alt="Cover art"/>
<p>The Scribe Test Book. A fixture for cross-file chapter boundaries.</p></div></body>
</html>'''

ch1 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Chapter One</title><style>p { margin: 0; }</style></head>
<body>
<h1>Chapter One</h1>
<p>It was a curious world&mdash;one that rewarded close reading.<a epub:type="noteref" href="#fn1">1</a></p>
<p>The margins were wide&nbsp;and the type was set generously.</p>
<img src="images/fig1.png" alt="A small figure"/>
<p>After the figure, the argument resumed with renewed vigor and a longer paragraph to give the tokenizer something to count.</p>
<aside epub:type="footnote" id="fn1">
<p>1. Close reading was, at the time, considered a radical act.</p>
</aside>
</body>
</html>'''

ch2 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter Two</title></head>
<body>
<h1>Chapter Two</h1>
<p>The second chapter opened with a promise it intended to keep.</p>
<h2 id="sec2">A Nested Section</h2>
<p>Sections nest, and the table of contents knows it.</p>
<div role="doc-footnote" id="fn2">Unnumbered note attached to the nested section.</div>
</body>
</html>'''

# ch3 opens with the tail of "A Nested Section" flowing across the spine-file
# split (no anchor of its own), then its OWN chapter begins mid-file at #c3.
# The old per-file segmenter forced ch3's first toc entry to paragraph 0, so the
# continuation leaked into Chapter Three; the global stream keeps it with the
# nested section it belongs to.
ch3 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter Three</title></head>
<body>
<p>The nested section continued here, flowing past the file split without a heading of its own.</p>
<h1 id="c3">Chapter Three</h1>
<p>Chapter three body begins after its own anchor, on a fresh spine document.</p>
</body>
</html>'''

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, 'sample.epub')
with zipfile.ZipFile(path, 'w') as z:
    z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    for name, content in [
        ('META-INF/container.xml', container),
        ('OEBPS/content.opf', opf),
        ('OEBPS/nav.xhtml', nav),
        ('OEBPS/toc.ncx', ncx),
        ('OEBPS/cover.xhtml', cover),
        ('OEBPS/ch1.xhtml', ch1),
        ('OEBPS/ch2.xhtml', ch2),
        ('OEBPS/ch3.xhtml', ch3),
    ]:
        z.writestr(name, content, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr('OEBPS/images/fig1.png', png, compress_type=zipfile.ZIP_STORED)
    # EPUB3 cover-image (manifest properties="cover-image"); reuses the 1x1 PNG.
    z.writestr('OEBPS/images/cover.png', png, compress_type=zipfile.ZIP_STORED)
print("wrote", path)
