#!/usr/bin/env swift
//
// render-pages.swift — Render PDF pages as PNGs for AI vision analysis
//
// Usage:
//   swift render-pages.swift <pdf-path> <output-dir> [--dpi 150] [--pages 1-10]
//
// Outputs JSON manifest to stdout.
//

import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

var args = CommandLine.arguments.dropFirst()

guard args.count >= 2 else {
    fputs("Usage: swift render-pages.swift <pdf-path> <output-dir> [--dpi 150] [--pages 1-10]\n", stderr)
    exit(1)
}

let pdfPath = args.removeFirst()
let outputDir = args.removeFirst()

var dpi: CGFloat = 150
var pageRange: ClosedRange<Int>? = nil

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dpi":
        guard !args.isEmpty, let v = Double(args.removeFirst()) else {
            fputs("--dpi requires a number\n", stderr); exit(1)
        }
        dpi = CGFloat(v)
    case "--pages":
        guard !args.isEmpty else {
            fputs("--pages requires a range like 1-10 or 5\n", stderr); exit(1)
        }
        let rangeStr = args.removeFirst()
        let parts = rangeStr.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 {
            pageRange = parts[0]...parts[1]
        } else if parts.count == 1 {
            pageRange = parts[0]...parts[0]
        } else {
            fputs("Invalid page range: \(rangeStr)\n", stderr); exit(1)
        }
    default:
        fputs("Unknown argument: \(arg)\n", stderr); exit(1)
    }
}

// ---------------------------------------------------------------------------
// Load PDF
// ---------------------------------------------------------------------------

let pdfURL = URL(fileURLWithPath: pdfPath)
guard let doc = PDFDocument(url: pdfURL) else {
    fputs("Failed to open PDF: \(pdfPath)\n", stderr)
    exit(1)
}

let totalPages = doc.pageCount
let range = pageRange ?? 1...totalPages

// Validate range
guard range.lowerBound >= 1 && range.upperBound <= totalPages else {
    fputs("Page range \(range) out of bounds (1-\(totalPages))\n", stderr)
    exit(1)
}

// Create output directory
let fm = FileManager.default
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// ---------------------------------------------------------------------------
// Render pages
// ---------------------------------------------------------------------------

var manifest: [[String: Any]] = []
let scale = dpi / 72.0  // PDF points are 72 DPI

for pageNum in range {
    let pageIndex = pageNum - 1  // PDFKit uses 0-based
    guard let page = doc.page(at: pageIndex) else {
        fputs("Warning: Could not get page \(pageNum)\n", stderr)
        continue
    }

    let mediaBox = page.bounds(for: .mediaBox)
    let width = Int(mediaBox.width * scale)
    let height = Int(mediaBox.height * scale)

    let filename = String(format: "page-%03d.png", pageNum)
    let outputPath = (outputDir as NSString).appendingPathComponent(filename)

    // Render to CGImage
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        fputs("Failed to create CGContext for page \(pageNum)\n", stderr)
        continue
    }

    // White background
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Scale and render
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)

    guard let cgImage = ctx.makeImage() else {
        fputs("Failed to render page \(pageNum)\n", stderr)
        continue
    }

    // Write PNG
    let url = URL(fileURLWithPath: outputPath)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("Failed to create image destination for page \(pageNum)\n", stderr)
        continue
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("Failed to write PNG for page \(pageNum)\n", stderr)
        continue
    }

    manifest.append([
        "index": pageIndex,
        "pageNumber": pageNum,
        "file": filename,
        "width": width,
        "height": height
    ])

    fputs("Rendered page \(pageNum)/\(range.upperBound) (\(width)x\(height))\n", stderr)
}

// ---------------------------------------------------------------------------
// Output manifest
// ---------------------------------------------------------------------------

let output: [String: Any] = [
    "pdf": pdfPath,
    "dpi": Int(dpi),
    "totalPages": totalPages,
    "renderedPages": manifest.count,
    "pages": manifest
]

let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: jsonData, encoding: .utf8)!)
