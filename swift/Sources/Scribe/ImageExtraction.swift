import Foundation
import PDFKit
import CoreGraphics

extension ScribeProcessor {

    // MARK: - Image Extraction

    func extractPageImages(page: PDFPage, pageIndex: Int, seenHashes: inout Set<Int>) -> [ExtractedImage] {
        guard let cgPage = page.pageRef else { return [] }

        var images: [ExtractedImage] = []
        let pageRect = page.bounds(for: .mediaBox)
        let pageRotation = page.rotation  // 0, 90, 180, 270

        // Scanned books store every page as one full-page JPEG XObject. Method 1
        // would happily extract those as "figures" and downstream renderers would
        // sprinkle full-page rasters into RSVP playback. Method 2 already refuses
        // page rasters via its `textLength < 100` guard; honor the same intent in
        // Method 1 by skipping image extraction wholesale on scanned books.
        // Scanned-OCR books, by definition, don't have meaningful figure XObjects
        // separate from page rasters — they have one big page-image per page.
        if bookProfile?.bookType == .scannedOCR {
            return []
        }

        // Method 1: Extract images from the PDF page's content streams via CGPDFPage
        // Handles DCTDecode (JPEG) and raw pixel data directly.
        let pageImages = extractImagesFromCGPDFPage(cgPage: cgPage, pageRect: pageRect, pageIndex: pageIndex, seenHashes: &seenHashes, pageRotation: pageRotation)
        images.append(contentsOf: pageImages)

        // Method 2: If XObject extraction found nothing, check if the page has
        // image XObjects we couldn't decode (JPXDecode/JPEG2000, JBIG2, etc.).
        // Only render pages with little text — these are illustration/plate pages.
        // Pages with substantial text (body pages with decorative borders) are skipped.
        let pageText = page.string ?? ""
        let textLength = pageText.trimmingCharacters(in: .whitespacesAndNewlines).count
        if images.isEmpty && textLength < 100 && pageHasImageXObjects(cgPage: cgPage) {
            if let rendered = renderPageToImage(page: page, maxDimension: 800) {
                let hash = rendered.count &+ pageIndex &* 31
                if !seenHashes.contains(hash) {
                    seenHashes.insert(hash)
                    let base64 = rendered.base64EncodedString()
                    let dataURI = "data:image/jpeg;base64,\(base64)"
                    let w = Int(pageRect.width)
                    let h = Int(pageRect.height)
                    images.append(ExtractedImage(
                        dataURI: dataURI,
                        width: w,
                        height: h,
                        pageIndex: pageIndex,
                        yPosition: 0.5
                    ))
                }
            }
        }

        return images
    }

    /// Check if a PDF page has image XObjects (without trying to decode them).
    func pageHasImageXObjects(cgPage: CGPDFPage) -> Bool {
        guard let dictionary = cgPage.dictionary else { return false }
        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resourcesDict),
              let resources = resourcesDict else { return false }
        var xObjectDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjectDict),
              let xObjects = xObjectDict else { return false }

        var hasImage = false
        CGPDFDictionaryApplyBlock(xObjects, { _, value, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let s = stream else { return true }
            guard let dict = CGPDFStreamGetDictionary(s) else { return true }
            var subtypeName: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dict, "Subtype", &subtypeName),
               let subtype = subtypeName, String(cString: subtype) == "Image" {
                var w: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dict, "Width", &w)
                if w >= 200 {  // Skip tiny decorative images
                    info?.assumingMemoryBound(to: Bool.self).pointee = true
                    return false  // stop iteration
                }
            }
            return true
        }, &hasImage)
        return hasImage
    }

    /// Render a PDF page to a JPEG image via CGContext.
    /// This handles all image encodings (JPX, JBIG2, etc.) since Core Graphics decodes them.
    func renderPageToImage(page: PDFPage, maxDimension: Int) -> Data? {
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(CGFloat(maxDimension) / pageRect.width, CGFloat(maxDimension) / pageRect.height, 2.0)
        let imageWidth = Int(pageRect.width * scale)
        let imageHeight = Int(pageRect.height * scale)

        guard imageWidth > 50 && imageHeight > 50 else { return nil }
        guard let cgImage = ScribeGraphics.renderPage(page, scale: scale) else { return nil }

        if let data = ScribeGraphics.jpegData(from: cgImage, quality: 0.5) {
            if data.count <= 500_000 { return data }
            return ScribeGraphics.jpegData(from: cgImage, quality: 0.3)
        }
        return nil
    }

    func extractImagesFromCGPDFPage(
        cgPage: CGPDFPage,
        pageRect: CGRect,
        pageIndex: Int,
        seenHashes: inout Set<Int>,
        pageRotation: Int = 0
    ) -> [ExtractedImage] {
        // Use CGPDFPage's content stream to find XObject images
        guard let dictionary = cgPage.dictionary else { return [] }

        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resourcesDict),
              let resources = resourcesDict else { return [] }

        var xObjectDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjectDict),
              let xObjects = xObjectDict else { return [] }

        var images: [ExtractedImage] = []

        // Iterate through XObjects looking for images
        var context = XObjectIteratorContext(
            images: &images,
            pageIndex: pageIndex,
            pageRect: pageRect,
            seenHashes: &seenHashes,
            pageRotation: pageRotation
        )

        withUnsafeMutablePointer(to: &context) { contextPtr in
            CGPDFDictionaryApplyBlock(xObjects, { key, value, info in
                guard let info = info else { return true }
                let ctx = info.assumingMemoryBound(to: XObjectIteratorContext.self)
                ScribeProcessor.processXObject(key: key, object: value, context: ctx)
                return true
            }, contextPtr)
        }

        return images
    }

    struct XObjectIteratorContext {
        var images: UnsafeMutablePointer<[ExtractedImage]>
        let pageIndex: Int
        let pageRect: CGRect
        var seenHashes: UnsafeMutablePointer<Set<Int>>
        let pageRotation: Int  // PDF page rotation (0, 90, 180, 270)
    }

    static func processXObject(key: UnsafePointer<CChar>, object: CGPDFObjectRef, context: UnsafeMutablePointer<XObjectIteratorContext>) {
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream),
              let pdfStream = stream else { return }

        guard let streamDict = CGPDFStreamGetDictionary(pdfStream) else { return }

        // Check if this is an image XObject
        var subtypeName: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypeName),
              let subtype = subtypeName,
              String(cString: subtype) == "Image" else { return }

        // Get image dimensions
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(streamDict, "Width", &width)
        CGPDFDictionaryGetInteger(streamDict, "Height", &height)

        // Skip tiny images (likely decorative: bullets, line separators, etc.)
        guard width >= 50 && height >= 50 else { return }

        // Skip page-rasters: XObjects whose pixel dimensions imply they cover
        // the entire page at ≥150dpi. Real figures embedded in digital books
        // rarely exceed ~1.5 megapixels; scanned pages at 200dpi are 3-4 MP
        // and at 150dpi are ~2 MP. Even when the book classifier misses
        // .scannedOCR (e.g. when the OCR text layer is dense enough that pages
        // don't look "illustrated"), the page-raster XObjects themselves are
        // a clear giveaway via pixel area.
        let pageWPts = context.pointee.pageRect.width   // 1pt = 1/72 inch
        let pageHPts = context.pointee.pageRect.height
        let pageAt150dpi = (pageWPts * 150.0 / 72.0) * (pageHPts * 150.0 / 72.0)
        let imgPixelArea = CGFloat(width) * CGFloat(height)
        if pageWPts > 0, pageHPts > 0, imgPixelArea > pageAt150dpi * 0.7 {
            return
        }

        // Get the raw image data
        var format: CGPDFDataFormat = .raw
        guard let data = CGPDFStreamCopyData(pdfStream, &format) else { return }

        let dataLength = CFDataGetLength(data)
        guard dataLength > 100 else { return } // Skip trivially small data

        // Deduplicate by content hash
        let hash = dataLength &+ Int(width) &* 31 &+ Int(height) &* 97
        guard !context.pointee.seenHashes.pointee.contains(hash) else { return }
        context.pointee.seenHashes.pointee.insert(hash)

        // Try to create a CGImage from the PDF image data
        let imgWidth = Int(width)
        let imgHeight = Int(height)

        // Check color space
        var bitsPerComponent: CGPDFInteger = 8
        CGPDFDictionaryGetInteger(streamDict, "BitsPerComponent", &bitsPerComponent)

        // For JPEG-encoded streams (DCTDecode), the data is already JPEG
        var filterName: UnsafePointer<CChar>?
        let isJPEG: Bool
        if CGPDFDictionaryGetName(streamDict, "Filter", &filterName),
           let filter = filterName {
            isJPEG = String(cString: filter) == "DCTDecode"
        } else {
            // Check if Filter is an array (e.g., [/DCTDecode])
            var filterArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(streamDict, "Filter", &filterArray),
               let arr = filterArray {
                var arrFilterName: UnsafePointer<CChar>?
                if CGPDFArrayGetName(arr, 0, &arrFilterName), let f = arrFilterName {
                    isJPEG = String(cString: f) == "DCTDecode"
                } else {
                    isJPEG = false
                }
            } else {
                isJPEG = false
            }
        }

        var imageData: Data
        if isJPEG {
            // Data is already JPEG — use directly
            imageData = data as Data
        } else {
            // Try to construct a CGImage from raw pixel data and compress to JPEG
            guard let cgImage = createCGImage(
                from: data as Data,
                width: imgWidth,
                height: imgHeight,
                bitsPerComponent: Int(bitsPerComponent),
                streamDict: streamDict
            ) else { return }

            guard let jpegData = ScribeGraphics.jpegData(from: cgImage, quality: 0.7) else { return }
            imageData = jpegData
        }

        // Apply page rotation to the extracted image if needed.
        // Raw XObject data is stored unrotated; we must apply the page's /Rotate.
        let rotation = context.pointee.pageRotation
        if rotation != 0, let srcImage = ScribeGraphics.cgImage(fromData: imageData) {
            if let rotated = ScribeGraphics.rotateImage(srcImage, degrees: rotation),
               let rotatedData = ScribeGraphics.jpegData(from: rotated, quality: 0.7) {
                imageData = rotatedData
            }
        }

        // Cap at 500KB per image to avoid huge payloads
        guard imageData.count < 500_000 else {
            // Re-compress at lower quality
            if let srcImage = ScribeGraphics.cgImage(fromData: imageData),
               let compressed = ScribeGraphics.jpegData(from: srcImage, quality: 0.4),
               compressed.count < 500_000 {
                let base64 = compressed.base64EncodedString()
                let dataURI = "data:image/jpeg;base64,\(base64)"
                context.pointee.images.pointee.append(ExtractedImage(
                    dataURI: dataURI,
                    width: imgWidth,
                    height: imgHeight,
                    pageIndex: context.pointee.pageIndex,
                    yPosition: 0.5
                ))
            }
            return
        }

        let base64 = imageData.base64EncodedString()
        let mimeType = isJPEG ? "image/jpeg" : "image/jpeg"
        let dataURI = "data:\(mimeType);base64,\(base64)"

        context.pointee.images.pointee.append(ExtractedImage(
            dataURI: dataURI,
            width: imgWidth,
            height: imgHeight,
            pageIndex: context.pointee.pageIndex,
            yPosition: 0.5 // Default to middle of page; refined later if position info available
        ))
    }

    static func createCGImage(
        from data: Data,
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        streamDict: CGPDFDictionaryRef
    ) -> CGImage? {
        // Determine color space
        var colorSpaceName: UnsafePointer<CChar>?
        let colorSpace: CGColorSpace
        var components = 3

        if CGPDFDictionaryGetName(streamDict, "ColorSpace", &colorSpaceName),
           let csName = colorSpaceName {
            let name = String(cString: csName)
            if name == "DeviceGray" {
                colorSpace = CGColorSpaceCreateDeviceGray()
                components = 1
            } else if name == "DeviceCMYK" {
                colorSpace = CGColorSpaceCreateDeviceCMYK()
                components = 4
            } else {
                colorSpace = CGColorSpaceCreateDeviceRGB()
                components = 3
            }
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }

        let expectedSize = width * height * components * bitsPerComponent / 8
        guard data.count >= expectedSize else { return nil }

        let bitmapInfo: CGBitmapInfo
        if components == 1 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        } else if components == 4 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        } else {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent * components,
            bytesPerRow: width * components * bitsPerComponent / 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

}
