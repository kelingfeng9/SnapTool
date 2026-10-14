import CoreGraphics
import Foundation
import ImageIO
import Vision

enum OCRServiceError: LocalizedError {
    case unsupportedLanguage(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let value): return "当前系统不支持 OCR 语言：\(value)。请选择自动识别。"
        }
    }
}

enum OCRService {
    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages().sorted()
    }

    /// Vision runs locally on a worker task. No image or recognized text leaves this Mac.
    static func recognize(image: CGImage, language: String? = nil) async throws -> String {
        try await recognize(image: image, languages: language.map { [$0] } ?? [])
    }

    static func recognize(image: CGImage, languages: [String]) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let supported = try request.supportedRecognitionLanguages()
                var selected = languages.filter { !$0.isEmpty }
                if !selected.isEmpty {
                    for language in selected {
                        guard supported.contains(language) else { throw OCRServiceError.unsupportedLanguage(language) }
                    }
                    if selected.contains(where: { $0.hasPrefix("zh") }),
                       !selected.contains("en-US"), supported.contains("en-US") { selected.append("en-US") }
                    request.recognitionLanguages = selected
                    request.automaticallyDetectsLanguage = false
                } else {
                    request.automaticallyDetectsLanguage = true
                    let preferred = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
                    if !preferred.isEmpty { request.recognitionLanguages = preferred }
                }
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()
                return readingOrder(request.results ?? [])
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private struct TextLine {
        var bounds: CGRect
        var items: [(CGRect, String)]
    }

    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> String {
        let items = observations.compactMap { observation -> (CGRect, String)? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return (observation.boundingBox, text)
        }.sorted { $0.0.midY > $1.0.midY }
        var lines: [TextLine] = []
        for item in items {
            // Vision coordinates start at the lower-left; higher rows are read first.
            if let index = lines.indices.first(where: {
                abs(lines[$0].bounds.midY - item.0.midY) <= min(lines[$0].bounds.height, item.0.height) * 0.45
            }) {
                lines[index].bounds = lines[index].bounds.union(item.0)
                lines[index].items.append(item)
            } else {
                lines.append(TextLine(bounds: item.0, items: [item]))
            }
        }
        return lines.sorted { $0.bounds.midY > $1.bounds.midY }.map { line in
            line.items.sorted { $0.0.minX < $1.0.minX }.map { $0.1 }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}
