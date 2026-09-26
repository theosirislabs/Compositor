import AppKit
import Testing
@testable import Compositor

/// History trims entries by how many bytes they hold, and the committed piece cache trims by how
/// many pixels it built. Both used to count a fraction of what they were keeping: a raster's
/// committed patches and its base were free, so the limits were fiction on exactly the documents
/// that needed them.
@MainActor
struct MemoryAccountingTests {
    /// A 2000px document with one tall stroke down its left side, which leaves the rest of the
    /// canvas unpainted. Small enough that the edit under test stays inside history's byte budget
    /// instead of being trimmed the moment it is recorded.
    private func painted() -> (session: EditorSession, asset: ImportedImage) {
        let session = EditorSession()
        session.createDocument(width: 2000, height: 2000)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 500, hardness: 0, red: 1, green: 1, blue: 1)
        session.beginBrush(at: CGPoint(x: 300, y: 1700))
        session.continueBrush(at: CGPoint(x: 300, y: 300))
        _ = session.finishBrushImmediately()
        return (session, session.activeLayer?.asset ?? ImportedImage(image: Self.blank(), thumbnail: Self.blank(), name: "empty"))
    }

    private static func blank() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// An entry's raster — its base and every committed patch — is what history is keeping, so it
    /// has to be charged. The live document is excluded from the count, so the raster has to leave
    /// it before history can be said to hold it: undo back past the stroke.
    @Test func historyCountsTheRasterBehindALayerNotJustItsImage() throws {
        let (session, asset) = painted()
        let history = session.history
        for _ in 0..<8 where session.document?.layers.contains(where: { $0.asset?.raster != nil }) == true {
            session.undo()
        }
        #expect(session.document?.layers.contains(where: { $0.asset?.raster != nil }) == false)
        let bytes = history.retainedBytes(current: session.document)
        let raster = try #require(asset.raster)
        var seen = Set<ObjectIdentifier>()
        let rasterBytes = raster.retainedBytes(excluding: &seen)
        #expect(rasterBytes > 0)
        // Both snapshots of the stroke are held, so history pays at least what one raster costs.
        #expect(bytes >= rasterBytes, "retained \(bytes) should cover the raster's \(rasterBytes)")
        // The old count saw only the flat image the layer shows, and that is well short of it.
        #expect(bytes > asset.image.bytesPerRow * asset.image.height)
    }

    /// Images the live document already holds are not charged to history, and the same image
    /// reached twice is charged once.
    @Test func historyExcludesTheLiveDocumentAndDeduplicates() throws {
        let (session, asset) = painted()
        let history = session.history
        #expect(history.retainedBytes(current: session.document) == 0, "the live document holds it all")
        for _ in 0..<8 where session.document?.layers.contains(where: { $0.asset?.raster != nil }) == true {
            session.undo()
        }
        let charged = history.retainedBytes(current: session.document)
        #expect(charged > 0)
        var seen = Set<ObjectIdentifier>()
        seen.insert(ObjectIdentifier(asset.image))
        seen.insert(ObjectIdentifier(asset.thumbnail))
        let after = try #require(asset.raster).retainedBytes(excluding: &seen)
        #expect(after < charged, "already-charged images should not be charged a second time")
    }

    /// A draw asks for the squares its viewport reaches. Building only those is the point — a
    /// raster with strokes across it should not cost the whole raster to look at one end — and a
    /// second look at the same ground should reuse what the first one built.
    @Test func pieceCacheBuildsTheViewportAndReusesIt() throws {
        let (_, asset) = painted()
        let raster = try #require(asset.raster)
        let cache = TiledPieceCache.shared
        cache.purge()
        let level = 0
        let margin = TiledLayerRenderer.support(level: level)
        let top = CGRect(x: 0, y: 1450, width: 800, height: 550)
        let bottom = CGRect(x: 0, y: 150, width: 800, height: 550)
        let first = cache.pieces(for: raster, level: level, visible: top)
        #expect(!first.isEmpty)
        for piece in first {
            #expect(top.insetBy(dx: -margin, dy: -margin).intersects(piece.interior))
        }
        let again = cache.pieces(for: raster, level: level, visible: top)
        #expect(again.count == first.count)
        for (a, b) in zip(first, again) { #expect(a.image === b.image) }
        // A different end of the stroke is a different set of squares, built alongside the first.
        let far = cache.pieces(for: raster, level: level, visible: bottom)
        #expect(!far.isEmpty)
        #expect(zip(first, far).allSatisfy { $0.image !== $1.image })
        // The first window's pieces are still held after the second request.
        let back = cache.pieces(for: raster, level: level, visible: top)
        for (a, b) in zip(first, back) { #expect(a.image === b.image) }
    }

    /// macOS sends no memory warning, so the caches let go when the app is not frontmost.
    @Test func cacheRegistryPurgesEverythingRegistered() throws {
        let (_, asset) = painted()
        let raster = try #require(asset.raster)
        let cache = TiledPieceCache.shared
        cache.purge()
        let window = CGRect(x: 0, y: 1450, width: 800, height: 550)
        let built = cache.pieces(for: raster, level: 0, visible: window)
        #expect(!built.isEmpty)
        RenderCacheRegistry.purge()
        let rebuilt = cache.pieces(for: raster, level: 0, visible: window)
        #expect(rebuilt.count == built.count)
        for (a, b) in zip(built, rebuilt) { #expect(a.image !== b.image) }
    }
}
