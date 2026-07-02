import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Cross-platform bitmap rendering and JPEG codec helpers.
/// Pure CoreGraphics/ImageIO so extraction behaves identically on iOS and macOS.
enum ScribeGraphics {

    private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Render a PDF page into a white-backed RGB bitmap at the given scale.
    static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)
        guard let ctx = makeBitmapContext(width: width, height: height) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Encode a CGImage as JPEG.
    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Decode encoded image bytes (JPEG etc.) back into a CGImage.
    static func cgImage(fromData data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Rotate an image clockwise by a PDF /Rotate angle (0, 90, 180, 270).
    static func rotateImage(_ image: CGImage, degrees: Int) -> CGImage? {
        let d = ((degrees % 360) + 360) % 360
        guard d == 90 || d == 180 || d == 270 else { return image }
        let w = image.width
        let h = image.height
        let outW = (d == 180) ? w : h
        let outH = (d == 180) ? h : w
        guard let ctx = makeBitmapContext(width: outW, height: outH) else { return nil }
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CGContext angles are counterclockwise; PDF /Rotate is clockwise
        ctx.rotate(by: -CGFloat(d) * .pi / 180)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
