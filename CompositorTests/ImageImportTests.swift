import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Testing
@testable import Compositor

@MainActor
struct ImageImportTests {
    func fixture(_ type: UTType, orientation: Int = 1, p3: Bool = false) throws -> URL {
        let colorSpace = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "image")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(arguments: [UTType.png, .jpeg, .tiff, .heic])
    func supportedFormats(type: UTType) async throws {
        let url = try fixture(type)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 64)
        #expect(result.image.height == 32)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(result.thumbnail.width <= 96)
        #expect(result.thumbnail.height <= 96)
    }

    @Test func orientationAndColorConversion() async throws {
        let url = try fixture(.tiff, orientation: 6, p3: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        #expect(result.image.width == 32)
        #expect(result.image.height == 64)
        #expect(result.image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func pngPreservesTransparency() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageImporter.shared.decode(url)
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 255)
        #expect(bytes[0] >= 250)
        #expect(bytes[63 * 4 + 3] == 0)
    }

    @Test func limitsAndInvalidFiles() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decode(url, remainingPixels: 10)
            Issue.record("Over-budget image should fail")
        } catch ImageImportError.tooLarge { }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("not an image".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            _ = try await ImageImporter.shared.decode(invalid)
            Issue.record("Invalid image should fail")
        } catch ImageImportError.unreadable { }
        let gif = try fixture(.gif)
        defer { try? FileManager.default.removeItem(at: gif) }
        do {
            _ = try await ImageImporter.shared.decode(gif)
            Issue.record("Unsupported image should fail")
        } catch ImageImportError.unsupported { }
    }

    @Test func importPlacementAndPartialFailure() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url, url])
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayerID == session.document?.layers.last?.id)
        session.createDocument(width: 128, height: 128)
        await session.importImages([url, url.appendingPathExtension("missing")])
        #expect(session.document?.size == CGSize(width: 128, height: 128))
        #expect(session.document?.layers.count == 1)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 32, y: 48))
        #expect(session.importError != nil)
        #expect(!session.isImporting)
    }

    @Test func dropPositionUsesDocumentCoordinates() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 1000, height: 800)
        session.viewport.resize(to: CGSize(width: 700, height: 500), backingScale: 2, documentSize: session.document?.size)
        session.zoom(to: 2.5)
        session.viewport.translate(by: CGSize(width: 70, height: -35))
        let location = session.viewport.viewPoint(from: CGPoint(x: 300, y: 250), documentSize: session.document!.size)
        let dropPoint = session.viewport.documentPoint(from: location, documentSize: session.document!.size)
        await session.importImages([url], at: dropPoint)
        #expect(session.document?.layers.first?.origin == CGPoint(x: 268, y: 234))
        #expect(session.document?.size == CGSize(width: 1000, height: 800))
    }

    @Test func queuedImportsAreNotLost() async throws {
        let url = try fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        let first = Task { await session.importImages([url, url], at: CGPoint(x: 999, y: 999)) }
        let second = Task { await session.importImages([url]) }
        await first.value
        await second.value
        #expect(session.document?.layers.count == 3)
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.first?.origin == .zero)
        #expect(!session.isImporting)
    }

    @Test func fileDropProvidersReachImporterInOrder() async throws {
        let first = try fixture(.png)
        let second = try fixture(.jpeg)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let session = EditorSession()
        let providers = [first, second].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        await ImageFileDrop.importProviders(providers, into: session, at: nil)
        #expect(session.document?.layers.map(\.name) == [first, second].map { $0.deletingPathExtension().lastPathComponent })
        #expect(session.importError == nil)
    }

    /// A 200×100 page with its bottom-right quadrant painted red; the rest is unpainted paper.
    func pdfFixture(pages: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw ImageImportError.unreadable }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// One pixel, rows counted from the image's top, through the same buffer layout the PNG transparency test reads.
    func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
    }

    /// A page whose crop and trim boxes are smaller than its media box, written by hand because
    /// CoreGraphics will not record the extra boxes.
    func boxedFixture() throws -> URL {
        let content = "0 0 1 rg\n0 0 200 100 re\nf\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /CropBox [0 0 100 50] /TrimBox [0 0 120 60] /Contents 4 0 R /Resources << /ProcSet [/PDF] >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    @Test func pdfCropBoxChoosesThePageBox() async throws {
        let url = try boxedFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var media = PDFImportOptions()
        media.box = .media
        let whole = try await ImageImporter.shared.decodePDF(url, options: media)
        #expect(whole[0].image.width == 200)
        #expect(whole[0].image.height == 100)
        var trim = PDFImportOptions()
        trim.box = .trim
        let finished = try await ImageImporter.shared.decodePDF(url, options: trim)
        #expect(finished[0].image.width == 120)
        #expect(finished[0].image.height == 60)
        // Crop is the default, and is what a viewer shows.
        let cropped = try await ImageImporter.shared.decodePDF(url)
        #expect(cropped[0].image.width == 100)
        #expect(cropped[0].image.height == 50)
    }

    @Test func pageNotationSelectsPages() {
        #expect(PDFImportOptions.parse("", pageCount: 3) == [1, 2, 3])
        #expect(PDFImportOptions.parse("2", pageCount: 3) == [2])
        #expect(PDFImportOptions.parse("1-2", pageCount: 4) == [1, 2])
        #expect(PDFImportOptions.parse("2-4, 1", pageCount: 5) == [1, 2, 3, 4])
        #expect(PDFImportOptions.parse("1-2, 2", pageCount: 3) == [1, 2])
        #expect(PDFImportOptions.parse("2-1", pageCount: 3) == [1, 2])
        #expect(PDFImportOptions.parse("9", pageCount: 3) == nil)
        #expect(PDFImportOptions.parse("two", pageCount: 3) == nil)
        #expect(PDFImportOptions.parse("1-", pageCount: 3) == nil)
    }

    @Test func pdfImportRendersEachPage() async throws {
        let url = try pdfFixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let pages = try await ImageImporter.shared.decodePDF(url)
        #expect(pages.count == 2)
        #expect(pages[0].image.width == 200)
        #expect(pages[0].image.height == 100)
        #expect(pages[0].name == "\(url.deletingPathExtension().lastPathComponent) — Page 1")
        #expect(pages[1].name == "\(url.deletingPathExtension().lastPathComponent) — Page 2")
        #expect(pages[0].thumbnail.width <= 96)
        // Painted bottom-right in the PDF lands bottom-right in the pixels, not flipped.
        let painted = try rgba(pages[0].image, x: 150, y: 75)
        #expect(painted[0] >= 250 && painted[3] == 255)
        // The paper behind it is white, as a page reads.
        let paper = try rgba(pages[0].image, x: 150, y: 25)
        #expect(paper[0] >= 250 && paper[1] >= 250 && paper[2] >= 250 && paper[3] == 255)
    }

    @Test func pdfResolutionSetsThePixelSize() async throws {
        let url = try pdfFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        // 72 ppi reads a point as a pixel; 300 ppi reads the same page at print size.
        var fine = PDFImportOptions()
        fine.resolution = 300
        let printed = try await ImageImporter.shared.decodePDF(url, options: fine)
        #expect(printed[0].image.width == 833)
        #expect(printed[0].image.height == 417)
        var middle = PDFImportOptions()
        middle.resolution = 150
        let half = try await ImageImporter.shared.decodePDF(url, options: middle)
        #expect(half[0].image.width == 417)
        #expect(half[0].image.height == 208)
    }

    @Test func pdfBackgroundAndPageChoiceAreHonored() async throws {
        let url = try pdfFixture(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        var transparent = PDFImportOptions()
        transparent.paper = .transparent
        let placed = try await ImageImporter.shared.decodePDF(url, options: transparent)
        #expect(placed[0].image.width == 200)
        // Placed over work, unpainted paper leaves nothing behind.
        let paper = try rgba(placed[0].image, x: 150, y: 25)
        #expect(paper[3] == 0)
        var second = PDFImportOptions()
        second.pages = "2"
        let one = try await ImageImporter.shared.decodePDF(url, options: second)
        #expect(one.count == 1)
        #expect(one[0].name == "\(url.deletingPathExtension().lastPathComponent) — Page 2")
        var third = PDFImportOptions()
        third.pages = "3"
        let named = try await ImageImporter.shared.decodePDF(url, options: third)
        #expect(named[0].name == "\(url.deletingPathExtension().lastPathComponent) — Page 3")
    }

    @Test func pdfImportHonorsTheDocumentBudget() async throws {
        let url = try pdfFixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ImageImporter.shared.decodePDF(url, remainingPixels: 10_000)
            Issue.record("A page over the remaining budget should fail")
        } catch ImageImportError.tooLarge { }
        var fine = PDFImportOptions()
        fine.resolution = 300
        let preview = PDFImportPreview.read(url, options: fine)
        #expect(preview.pageCount == 2)
        #expect(preview.selected == [1, 2])
        #expect(preview.pixelRange == "833 × 417 pixels")
        #expect(preview.totalPixels == 2 * 833 * 417)
    }

    @Test func pdfReachesTheSessionAsLayers() async throws {
        let url = try pdfFixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmPDFImport = { _, options in options }
        await session.importImages([url])
        #expect(session.importError == nil)
        #expect(session.document?.size == CGSize(width: 200, height: 100))
        #expect(session.document?.layers.count == 2)
    }

    @Test func cancellingThePDFSheetImportsNothing() async throws {
        let url = try pdfFixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmPDFImport = { _, _ in nil }
        await session.importImages([url])
        #expect(session.document == nil)
        #expect(session.importError == nil)
        #expect(!session.isImporting)
    }
}
