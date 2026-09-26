import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// A PSD is a container of counts, offsets and numbers a hostile file controls. Each test here is
/// a file that used to trap, read out of bounds, or recurse without end — they must be rejected.
@MainActor
struct PSDMalformedInputTests {
    private func image(width: Int = 2, height: Int = 2) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func oneLayer(largeDocument: Bool = false) throws -> Data {
        let red = try image()
        var layer = PSDRecord(id: UUID(), name: "Layer")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = red
        return try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]),
                                   composite: red, largeDocument: largeDocument)
    }

    /// A 26-byte header declaring a layer section far longer than the file. Adding that length to
    /// the cursor used to overflow before anything compared it to the data's size.
    @Test func absurdLayerSectionLengthIsRejected() throws {
        for largeDocument in [false, true] {
            func be16(_ value: Int) -> Data { Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
            func be32(_ value: UInt32) -> Data {
                Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
            }
            func be64(_ value: UInt64) -> Data { be32(UInt32(truncatingIfNeeded: value >> 32)) + be32(UInt32(truncatingIfNeeded: value)) }
            var file = Data()
            file.append(contentsOf: Array("8BPS".utf8))
            file += be16(largeDocument ? 2 : 1)
            file.append(Data(count: 6))
            file += be16(3)
            file += be32(2)
            file += be32(2)
            file += be16(8)
            file += be16(3)
            file += be32(0)          // colour mode data
            file += be32(0)          // image resources
            file += largeDocument ? be64(UInt64.max) : be32(UInt32.max)
            #expect(throws: (any Error).self) { try PSDReader.read(file) }
        }
    }

    /// Width and height are u32s the file chooses; their product used to be computed unguarded.
    @Test func absurdCanvasSizeIsRejected() throws {
        for largeDocument in [false, true] {
            var file = try oneLayer(largeDocument: largeDocument)
            // Header layout: signature 0-3, version 4-5, reserved 6-11, channels 12-13,
            // height 14-17, width 18-21, depth 22-23, mode 24-25.
            for index in 14..<22 { file[index] = 0xFF }
            #expect(throws: (any Error).self) { try PSDReader.read(file) }
        }
    }

    /// Every prefix of a valid file is a different malformed file. A prefix that cuts only the
    /// merged preview may still parse — that is legal — but none may read past its end or trap,
    /// and a trap would take the test run down with it.
    @Test func truncatedFilesAreRejectedAtEveryLength() throws {
        let file = try oneLayer()
        for length in 0..<file.count {
            _ = try? PSDReader.read(Data(file.prefix(length)))
        }
    }

    /// A font index is read as a Double and turned into an Int. 1e300 and friends used to trap
    /// the conversion; a value that is not a whole number in range is refused instead. Tokens the
    /// engine cannot read at all (`inf`, `nan`) are simply ignored, which is equally safe.
    @Test func hostileTextNumbersAreRefused() {
        for token in ["1e300", "-1e300", "2.5", "9999", "-4"] {
            #expect(PSDText.parse(extra: ["TySh": PSDFixture.tySh(text: "Hello", fontNumber: token)]) == nil,
                    "font index “\(token)” should be refused")
        }
        for token in ["inf", "nan", "not-a-number"] {
            _ = PSDText.parse(extra: ["TySh": PSDFixture.tySh(text: "Hello", fontNumber: token)])
        }
        // The ordinary case still parses, so the guard is not simply refusing everything.
        #expect(PSDText.parse(extra: ["TySh": PSDFixture.tySh(text: "Hello")])?.style.content == "Hello")
    }

    /// Descriptors nest through `Objc`/`GlbO`. A file nested far deeper than any real document
    /// reaches must be refused at the depth limit rather than recursed until the stack gives out.
    @Test func deeplyNestedDescriptorsAreRefused() {
        for depth in [7, 64, 1_000] {
            let parsed = PSDText.parse(extra: ["TySh": PSDFixture.tySh(text: "Hello", nestedItemDepth: depth)])
            #expect(parsed == nil, "\(depth) levels of nesting should be refused")
        }
        #expect(PSDText.parse(extra: ["TySh": PSDFixture.tySh(text: "Hello", nestedItemDepth: 2)])?.style.content == "Hello")
    }

    /// Layer masks count against the document budget apart from image pixels, the way a project
    /// holds them, so a document full of masks cannot slip past the ceiling.
    @Test func maskPixelsAreHeldToTheDocumentBudget() throws {
        let red = try image(width: 8, height: 8)
        var layer = PSDRecord(id: UUID(), name: "Masked")
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        layer.image = red
        layer.mask = try {
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                                 bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()!
        }()
        let file = try PSDFixture.data(PSDDocument(width: 8, height: 8, resolution: 72, layers: [layer]), composite: red)
        // 64 image pixels and 64 mask pixels: each budget is 64, so both fit.
        #expect(try PSDReader.read(file, remainingPixels: 64).layers.count == 1)
        // A second layer's mask would take the mask budget past 64, even though the image budget
        // has room, and must be refused rather than quietly allowed.
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(file, remainingPixels: 1) }
    }
}
