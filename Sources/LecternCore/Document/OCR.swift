import CoreGraphics
import Foundation
import Vision

/// Text recognition for scanned pages (Vision, on-device). Thread-safe: works on a CGImage only.
enum PageOCR {
    /// Recognized text in reading order: rows top to bottom (cells of a table row stay on one line),
    /// and a two-column layout read column by column.
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Verified to read English, Chinese and mixed pages; a fixed ["zh-Hans", "en-US"] list garbles English.
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let items: [(text: String, box: CGRect)] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (text, observation.boundingBox)
        }
        return layout(items)
    }

    /// Boxes are normalized with the origin at the bottom left.
    static func layout(_ items: [(text: String, box: CGRect)]) -> String {
        let left = items.filter { $0.box.maxX <= 0.52 }
        let right = items.filter { $0.box.minX >= 0.48 }
        let median: ([(text: String, box: CGRect)]) -> CGFloat = { group in
            let widths = group.map(\.box.width).sorted()
            return widths.isEmpty ? 0 : widths[widths.count / 2]
        }
        // Two columns of running text: wide lines on each side, few spanning the middle (a table's
        // cells are narrow, so it stays row by row).
        if left.count >= 4, right.count >= 4, items.count - left.count - right.count <= items.count / 10,
           median(left) > 0.3, median(right) > 0.3 {
            let spanning = items.filter { $0.box.maxX > 0.52 && $0.box.minX < 0.48 }
            return [rows(spanning + left), rows(right)].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return rows(items)
    }

    private static func rows(_ items: [(text: String, box: CGRect)]) -> String {
        var rows: [[(text: String, box: CGRect)]] = []
        for item in items.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.last, abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// False for a blank render (nothing darker than paper), so empty pages skip recognition.
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        var dark = 0, sampled = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let offset = y * image.bytesPerRow + x * 4
                guard offset + 2 < length else { continue }
                sampled += 1
                if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 160 { dark += 1 }
            }
        }
        return sampled > 0 && dark * 2000 >= sampled   // ≥ 0.05% ink
    }
}
