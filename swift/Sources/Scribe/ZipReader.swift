import Foundation
import Compression

/// Minimal read-only ZIP parser, sufficient for EPUB containers.
/// Supports stored (method 0) and deflate (method 8) entries.
/// No encryption, no zip64 — EPUBs that need those are out of scope.
struct ZipReader {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    private static let eocdSignature: UInt32 = 0x06054b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let localSignature: UInt32 = 0x04034b50

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d)
    }

    init?(data: Data) {
        self.data = data
        guard let eocd = ZipReader.findEndOfCentralDirectory(in: data) else { return nil }
        let entryCount = Int(data.zipLE16(at: eocd + 10))
        var p = Int(data.zipLE32(at: eocd + 16))

        for _ in 0..<entryCount {
            guard p + 46 <= data.count, data.zipLE32(at: p) == ZipReader.centralSignature else { return nil }
            let method = data.zipLE16(at: p + 10)
            let compressedSize = Int(data.zipLE32(at: p + 20))
            let uncompressedSize = Int(data.zipLE32(at: p + 24))
            let nameLen = Int(data.zipLE16(at: p + 28))
            let extraLen = Int(data.zipLE16(at: p + 30))
            let commentLen = Int(data.zipLE16(at: p + 32))
            let localOffset = Int(data.zipLE32(at: p + 42))
            guard p + 46 + nameLen <= data.count else { return nil }
            guard let name = String(data: data.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) else {
                p += 46 + nameLen + extraLen + commentLen
                continue
            }
            entries[name] = Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            )
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Decompressed contents of the named entry, or nil if absent/unsupported.
    func contents(of name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let lho = entry.localHeaderOffset
        guard lho + 30 <= data.count, data.zipLE32(at: lho) == ZipReader.localSignature else { return nil }
        // Local header name/extra lengths can differ from the central directory's.
        let nameLen = Int(data.zipLE16(at: lho + 26))
        let extraLen = Int(data.zipLE16(at: lho + 28))
        let start = lho + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return raw
        case 8:
            return ZipReader.inflate(raw, uncompressedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// ZIP entries deflate without the zlib header, which is exactly what
    /// Compression's COMPRESSION_ZLIB decoder expects.
    private static func inflate(_ src: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        guard !src.isEmpty else { return nil }
        var dst = Data(count: uncompressedSize)
        let decoded = dst.withUnsafeMutableBytes { dstPtr -> Int in
            src.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == uncompressedSize else { return nil }
        return dst
    }

    /// Locate the End of Central Directory record by scanning backwards
    /// through the maximum possible trailing comment (64KB + 22 bytes).
    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let scanLimit = max(0, data.count - 22 - 65_535)
        var p = data.count - 22
        while p >= scanLimit {
            if data.zipLE32(at: p) == eocdSignature {
                return p
            }
            p -= 1
        }
        return nil
    }
}

private extension Data {
    func zipLE16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func zipLE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
