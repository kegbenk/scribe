import CoreGraphics
import DataDetection
import Foundation
import Vision

/// Vision framework integration for structural document analysis.
/// Uses RecognizeDocumentsRequest (iOS 26+) for paragraph, table, list, and data detection.
@available(iOS 26.0, macOS 26.0, *)
struct StructuralAnalyzer {

    /// Analyze a document page image for structural elements.
    /// Returns detected paragraphs, tables, lists, and structured data (emails, phones, URLs).
    static func analyzePageStructure(of image: CGImage) async throws -> PageStructure {
        let request = RecognizeDocumentsRequest()

        let observations = try await request.perform(on: image)

        guard let observation = observations.first else {
            return PageStructure(
                transcript: "",
                paragraphs: [],
                tables: [],
                lists: [],
                detectedData: []
            )
        }

        let document = observation.document

        // Full transcript
        let transcript = document.text.transcript

        // Individual paragraphs
        let paragraphs = document.paragraphs.map { $0.transcript }

        // Tables: rows is [[Cell]], each cell's content is a Container
        let tables = document.tables.map { table in
            TableData(rows: table.rows.map { row in
                row.map { cell in cell.content.text.transcript }
            })
        }

        // Lists: items have .itemString for direct text access
        let lists = document.lists.map { list in
            ListData(items: list.items.map { $0.itemString })
        }

        // Detected structured data (emails, phones, URLs) from the text layer
        let detectedData = extractDetectedData(from: document.text)

        return PageStructure(
            transcript: transcript,
            paragraphs: paragraphs,
            tables: tables,
            lists: lists,
            detectedData: detectedData
        )
    }

    /// Perform OCR text recognition on a page image.
    /// Simpler than full document analysis — returns just the recognized text lines.
    static func recognizeText(in image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate

        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: - Private

    private static func extractDetectedData(
        from text: DocumentObservation.Container.Text
    ) -> [DetectedDataItem] {
        var items: [DetectedDataItem] = []

        for detected in text.detectedData {
            switch detected.match.details {
            case .emailAddress(let email):
                items.append(DetectedDataItem(type: .email, value: email.emailAddress))
            case .phoneNumber(let phone):
                items.append(DetectedDataItem(type: .phoneNumber, value: phone.phoneNumber))
            case .link(let link):
                items.append(DetectedDataItem(type: .url, value: link.url.absoluteString))
            case .postalAddress(let address):
                items.append(DetectedDataItem(type: .address, value: address.fullAddress))
            case .calendarEvent(let event):
                if let start = event.startDate {
                    items.append(DetectedDataItem(type: .date, value: ISO8601DateFormatter().string(from: start)))
                }
            default:
                break
            }
        }

        return items
    }
}
