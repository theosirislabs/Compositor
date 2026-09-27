import AppKit
import Testing
@testable import Compositor

/// A layer kept at full resolution while it is painted, brought up to date only where the paint
/// changed. Nothing tested that before: the surface is what the brush's live preview comes from, and
/// what a stale or half-updated surface means is a layer that looks wrong until the stroke ends.
@MainActor
struct LayerEffectsSurfaceTests {
    private struct RGBA: Equatable { let r, g, b, a: Int }

    private func image(width: Int, height: Int, red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> RGBA {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return RGBA(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]), a: Int(bytes[offset + 3]))
    }


    private func pixels(_ image: CGImage) throws -> [RGBA] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width * image.height).map {
            RGBA(r: Int(bytes[$0 * 4]), g: Int(bytes[$0 * 4 + 1]), b: Int(bytes[$0 * 4 + 2]), a: Int(bytes[$0 * 4 + 3]))
        }
    }

    private func count(where matches: (RGBA) -> Bool, in image: CGImage) throws -> Int {
        try pixels(image).filter(matches).count
    }

    private func region(of image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> [RGBA] {
        let all = try pixels(image)
        return (0..<height).flatMap { row in
            let start = (y + row) * image.width + x
            return Array(all[start..<start + width])
        }
    }

    private var effects: LayerEffects {
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 4, red: 0, green: 0, blue: 0, opacity: 1, inside: false)
        return effects
    }

    /// A first pass covers everything: the layer's pixels, with the stroke around them.
    @Test func firstPassDrawsTheLayerAndItsEffects() throws {
        let grid = CGSize(width: 64, height: 64)
        let source = CGRect(x: 0, y: 0, width: 48, height: 48)
        let surface = try #require(LayerEffectsSurface(layerID: UUID(), effects: effects, grid: grid, sourceRect: source))
        surface.update(base: try image(width: 48, height: 48, red: 1, green: 0, blue: 0), patches: [], mask: nil)
        let built = try #require(surface.image)
        #expect(CGFloat(built.width) > source.width, "the surface leaves room for the stroke")
        #expect(try rgba(built, x: built.width / 2, y: built.height / 2).r > 200)
    }

    /// Paint in one corner must land, and must not disturb the rest of the surface: a dab ten
    /// pixels across should not recompose a seventy-six-pixel layer.
    @Test func aLaterDabLandsWithoutRepaintingTheWholeSurface() throws {
        let grid = CGSize(width: 64, height: 64)
        let source = CGRect(x: 0, y: 0, width: 48, height: 48)
        let surface = try #require(LayerEffectsSurface(layerID: UUID(), effects: effects, grid: grid, sourceRect: source))
        let base = try image(width: 48, height: 48, red: 1, green: 0, blue: 0)
        surface.update(base: base, patches: [], mask: nil)
        let first = try #require(surface.image)
        #expect(try count(where: { $0.r > 200 && $0.g < 80 }, in: first) > 0, "the layer's own red should be there")

        // Green paint in one corner of the layer.
        let patch = BrushPatch(rect: CGRect(x: 2, y: 2, width: 10, height: 10),
                               image: try image(width: 10, height: 10, red: 0, green: 1, blue: 0))
        surface.update(base: base, patches: [patch], mask: nil)
        let second = try #require(surface.image)
        #expect(second !== first, "the surface should have been recomposed")
        #expect(try count(where: { $0.g > 200 && $0.r < 80 }, in: second) > 0, "the new paint should be visible")

        // The far corner, which a dab in the top left cannot reach, is byte for byte what it was.
        let untouched = try region(of: first, x: second.width - 12, y: second.height - 12, width: 12, height: 12)
        #expect(try region(of: second, x: second.width - 12, y: second.height - 12, width: 12, height: 12) == untouched)
    }

    /// A patch that has not changed is not treated as new work on the next update.
    @Test func anUnchangedPatchIsNotRedrawnAgain() throws {
        let grid = CGSize(width: 64, height: 64)
        let surface = try #require(LayerEffectsSurface(layerID: UUID(), effects: effects, grid: grid,
                                                      sourceRect: CGRect(x: 0, y: 0, width: 48, height: 48)))
        let base = try image(width: 48, height: 48, red: 1, green: 0, blue: 0)
        let patch = BrushPatch(rect: CGRect(x: 4, y: 4, width: 8, height: 8),
                               image: try image(width: 8, height: 8, red: 0, green: 0, blue: 1))
        surface.update(base: base, patches: [patch], mask: nil)
        let first = try #require(surface.image)
        // The same patch again: nothing about the layer changed, so the surface is left alone.
        surface.update(base: base, patches: [patch], mask: nil)
        #expect(surface.image === first)
        // A different image in the same place is new work.
        let moved = BrushPatch(rect: CGRect(x: 4, y: 4, width: 8, height: 8),
                               image: try image(width: 8, height: 8, red: 1, green: 1, blue: 0))
        surface.update(base: base, patches: [moved], mask: nil)
        #expect(surface.image !== first)
    }

    /// A surface belongs to the layer, settings, grid and source placement it was made for; a stroke
    /// that changes any of them needs a new one rather than a stale recompose.
    @Test func matchesOnlyTheSurfaceItWasMadeFor() throws {
        let id = UUID()
        let grid = CGSize(width: 64, height: 64)
        let source = CGRect(x: 0, y: 0, width: 48, height: 48)
        let surface = try #require(LayerEffectsSurface(layerID: id, effects: effects, grid: grid, sourceRect: source))
        #expect(surface.matches(layerID: id, effects: effects, grid: grid, sourceRect: source))
        #expect(!surface.matches(layerID: UUID(), effects: effects, grid: grid, sourceRect: source))
        #expect(!surface.matches(layerID: id, effects: LayerEffects(), grid: grid, sourceRect: source))
        #expect(!surface.matches(layerID: id, effects: effects, grid: CGSize(width: 96, height: 64), sourceRect: source))
        #expect(!surface.matches(layerID: id, effects: effects, grid: grid,
                                 sourceRect: CGRect(x: 8, y: 0, width: 48, height: 48)))
    }

    /// The surface is handed on when the stroke ends, so the finished layer is drawn with it.
    @Test func placementIsCarriedForTheStrokeToHandOn() throws {
        let surface = try #require(LayerEffectsSurface(layerID: UUID(), effects: effects,
                                                      grid: CGSize(width: 64, height: 64),
                                                      sourceRect: CGRect(x: 0, y: 0, width: 48, height: 48)))
        #expect(surface.placement == nil)
        surface.placement = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 64, height: 64))
        #expect(surface.placement?.origin == CGPoint(x: 10, y: 20))
    }
}
