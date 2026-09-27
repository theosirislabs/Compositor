import CoreGraphics
import Foundation

/// How a PDF is turned into pixels. A PDF page has no resolution of its own — it is measured in points,
/// 1/72 inch — so the resolution asked for here is what decides the size of the layer, the way it does
/// in Photoshop's Import PDF dialog. Pages come in as layers, one per page, at 1:1 with the pixels.
nonisolated struct PDFImportOptions: Equatable, Sendable {
    /// Which of the page's boxes to read. Crop is what a viewer shows; the others are the marks a
    /// print workflow leaves behind.
    enum Box: String, CaseIterable, Sendable {
        case crop, media, bleed, trim, art

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() + " Box" }
        var pageBox: CGPDFBox {
            switch self {
            case .crop: .cropBox
            case .media: .mediaBox
            case .bleed: .bleedBox
            case .trim: .trimBox
            case .art: .artBox
            }
        }
    }

    /// What shows through where the page paints nothing. White reads as paper; transparent places the
    /// artwork over the canvas with nothing behind it.
    enum Paper: String, CaseIterable, Sendable {
        case white, transparent

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    static let pointInch: Double = 72
    static let presetResolutions: [Double] = [72, 150, 300, 600]

    var box: Box = .crop
    var resolution: Double = pointInch
    var paper: Paper = .white
    /// Empty means every page. Otherwise Photoshop's notation: "2", "2-4", "1-3, 7".
    var pages = ""

    var scale: Double { resolution / Self.pointInch }

    func selectedPages(pageCount: Int) -> [Int] { Self.parse(pages, pageCount: pageCount) ?? [] }

    /// The 1-based pages the notation asks for, or nil when it asks for none of them.
    static func parse(_ text: String, pageCount: Int) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(1...max(1, pageCount)) }
        var chosen: Set<Int> = []
        for part in trimmed.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard ends.count == 1 || ends.count == 2 else { return nil }
            let numbers = ends.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == ends.count else { return nil }
            if numbers.count == 1 {
                chosen.insert(numbers[0])
            } else {
                let low = max(1, min(numbers[0], numbers[1])), high = min(max(1, pageCount), max(numbers[0], numbers[1]))
                guard high >= low else { return nil }
                chosen.formUnion(low...high)
            }
        }
        let valid = chosen.filter { $0 >= 1 && $0 <= pageCount }.sorted()
        return valid.isEmpty ? nil : valid
    }

    /// The pixels a page lands in, with its /Rotate already turned the way it is read.
    func pixelSize(page: CGPDFPage) -> (width: Int, height: Int)? {
        let rect = page.getBoxRect(box.pageBox)
        let turned = page.rotationAngle % 180 != 0
        let points = turned ? CGSize(width: rect.height, height: rect.width) : rect.size
        guard points.width > 0, points.height > 0 else { return nil }
        return (max(1, Int((points.width * scale).rounded())), max(1, Int((points.height * scale).rounded())))
    }
}

/// The page numbers and pixel sizes the sheet previews, read from the file without drawing it.
nonisolated struct PDFImportPreview: Sendable {
    var pageCount: Int = 0
    var selected: [Int] = []
    var smallest: (width: Int, height: Int)?
    var largest: (width: Int, height: Int)?
    var totalPixels: Int = 0

    var pixelRange: String? {
        guard let smallest, let largest else { return nil }
        return smallest == largest ? "\(smallest.width) × \(smallest.height) pixels"
            : "\(smallest.width) × \(smallest.height) – \(largest.width) × \(largest.height) pixels"
    }
    var megapixels: Double { Double(totalPixels) / 1_000_000 }
    var overBudget: Bool { totalPixels > DocumentLimits.documentPixelBudget }
    var overSideLimit: Bool {
        let sides = [smallest?.width, smallest?.height, largest?.width, largest?.height].compactMap { $0 }
        return sides.contains { $0 > DocumentLimits.maxSide }
    }

    static func read(_ url: URL, options: PDFImportOptions) -> PDFImportPreview {
        var preview = PDFImportPreview()
        guard let document = CGPDFDocument(url as CFURL) else { return preview }
        preview.pageCount = document.numberOfPages
        preview.selected = options.selectedPages(pageCount: document.numberOfPages)
        for index in preview.selected {
            guard let page = document.page(at: index), let size = options.pixelSize(page: page) else { continue }
            preview.totalPixels += size.width * size.height
            let area = size.width * size.height
            if let currentSmallest = preview.smallest, let currentLargest = preview.largest {
                if area < currentSmallest.width * currentSmallest.height { preview.smallest = size }
                if area > currentLargest.width * currentLargest.height { preview.largest = size }
            } else {
                preview.smallest = size
                preview.largest = size
            }
        }
        return preview
    }
}
