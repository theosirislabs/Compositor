import AppKit
import Testing
@testable import Compositor

@MainActor
struct SmudgeLiquifyTests {
    private func stripedAsset() throws -> ImportedImage {
        let context = try BrushRaster.context(width: 80, height: 80, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 40, y: 0, width: 40, height: 80))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Stripes")
    }

    private func session(_ mode: BlurToolMode) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 80, height: 80)
        session.insert(try stripedAsset())
        session.selectTool(.blur)
        session.blurMode = mode
        session.brushSettings = BrushSettings(diameter: 12, hardness: 1, opacity: 1)
        return session
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Data(bytes: data, count: context.bytesPerRow * image.height)
    }

    @Test func smudgeAndBlurStrokesChangeTheTargetLayer() async throws {
        for mode in [BlurToolMode.smudge, .blur] {
            let session = try session(mode)
            let original = try #require(session.activeLayer?.asset?.image)
            let before = try pixels(original)
            let count = session.history.undoCount
            session.beginBrush(at: CGPoint(x: 20, y: 40))
            session.continueBrush(at: CGPoint(x: 60, y: 40))
            if mode == .smudge {
                #expect(session.warpStroke != nil)
                #expect(session.brushStroke == nil)
            } else {
                #expect(session.brushStroke != nil)
                #expect(session.warpStroke == nil)
            }
            await session.finishBrush()
            #expect(session.warpStroke == nil)
            #expect(session.brushStroke == nil)
            let updated = try #require(session.activeLayer?.asset?.image)
            #expect(updated !== original)
            #expect(try pixels(updated) != before)
            #expect(session.history.undoCount == count + 1)
        }
    }

    @Test func warpRefusesToStartWhileTheSessionCannotEditLayers() throws {
        let session = try session(.smudge)
        let before = session.document
        let count = session.history.undoCount
        session.beginProjectOperation()
        #expect(!session.canEditLayers)
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        session.continueBrush(at: CGPoint(x: 60, y: 40))
        #expect(session.warpStroke == nil)
        #expect(session.document == before)
        #expect(session.history.undoCount == count)
        session.endProjectOperation()
    }

    @Test func cancellingWarpLeavesTheDocumentUnchanged() throws {
        let session = try session(.liquify)
        let before = session.document
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 20, y: 40))
        session.continueBrush(at: CGPoint(x: 60, y: 40))
        #expect(session.warpStroke != nil)
        session.cancelBrush()
        #expect(session.warpStroke == nil)
        #expect(session.document == before)
        #expect(session.history.undoCount == count)
    }
}
