import AppKit
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Canvas Size, Image Size and Trim all rebuild the document from a snapshot. Every layer field
/// that is not pixels has to survive that trip: dropping one silently deletes the user's work,
/// because nothing renders the lost field and nothing reports it.
@MainActor
struct ResizePreservesLayerMetadataTests {
    private func decorated() async throws -> (session: EditorSession, effects: LayerEffects, id: UUID) {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 8, red: 0.1, green: 0.8, blue: 0.2, opacity: 0.9, inside: false)
        effects.shadow = ShadowEffect(angle: 45, distance: 15, blur: 10, red: 0.2, green: 0.2, blue: 0.3, opacity: 0.75)
        session.setEffects(effects, on: id)
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
        return (session, effects, id)
    }

    @Test func canvasSizeKeepsLayerEffects() async throws {
        let (session, effects, id) = try await decorated()
        let snapshot = try #require(session.projectSnapshot())
        let resized = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 96, height: 72, anchor: 4))
        session.applyDocumentSize(resized, actionName: "Canvas Size")
        #expect(session.document?.size == CGSize(width: 96, height: 72))
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
        session.undo()
        #expect(session.document?.size == CGSize(width: 64, height: 32))
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
    }

    @Test func imageSizeKeepsLayerEffects() async throws {
        let (session, effects, id) = try await decorated()
        let snapshot = try #require(session.projectSnapshot())
        let resized = try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(
            width: 128, height: 64, resolution: 72, sampling: .high))
        session.applyDocumentSize(resized, actionName: "Image Size")
        #expect(session.document?.layers.first { $0.id == id }?.transform.size == CGSize(width: 128, height: 64))
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
    }

    @Test func trimKeepsLayerEffects() async throws {
        let (session, effects, id) = try await decorated()
        let snapshot = try #require(session.projectSnapshot())
        let trimmed = try #require(try await ImageTrim.trim(snapshot, options: TrimOptions(basedOn: .topLeftPixelColor)))
        session.applyDocumentSize(trimmed, actionName: "Trim")
        #expect(session.document?.layers.first { $0.id == id }?.effects == effects)
    }

    @Test func resizeKeepsLiveShapeAndText() async throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 120, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 60, y: 50), square: false, fromCenter: false)
        session.finishShape()
        let shapeID = try #require(session.activeLayerID)
        let style = try #require(session.activeLayer?.liveShape?.style)

        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 80, y: 30))
        var draft = try #require(session.textDraft)
        draft.style.content = "Note"
        #expect(session.applyText(draft))
        let textID = try #require(session.activeLayerID)
        let content = try #require(session.activeLayer?.liveText?.style.content)

        let snapshot = try #require(session.projectSnapshot())
        let resized = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 300, height: 200, anchor: 0))
        session.applyDocumentSize(resized, actionName: "Canvas Size")

        let shape = try #require(session.document?.layers.first { $0.id == shapeID })
        #expect(shape.liveShape?.style == style)
        let text = try #require(session.document?.layers.first { $0.id == textID })
        #expect(text.liveText?.style.content == content)
    }

    /// A package may not carry effect or shape values the renderer would choke on; the manifest
    /// validated neither, so a hand-edited file could reach the renderer with NaN colours.
    @Test func invalidEffectsAndShapesAreRejected() async throws {
        let (session, _, _) = try await decorated()
        let snapshot = try #require(session.projectSnapshot())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Bad.comp")

        func withBadLayer(_ edit: (inout ProjectLayerRecord) -> Void) -> ProjectSnapshot {
            var manifest = snapshot.manifest
            edit(&manifest.layers[0])
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        }
        // Save and load share one validator, so refusing to write is the same guarantee as
        // refusing to read, checked once.
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: .nan, red: 0, green: 0, blue: 0, opacity: 1, inside: false)
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(withBadLayer { $0.effects = effects }, to: url)
        }
        var style = LayerShapeStyle(kind: .rectangle, red: .infinity, green: 0, blue: 0, cornerRadius: 0)
        style.cornerRadius = .nan
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(withBadLayer { $0.shape = style }, to: url)
        }
    }

    /// The validators themselves, so a new effect or shape field cannot slip past untested.
    @Test func effectAndShapeValidatorsRejectHostileNumbers() {
        var effects = LayerEffects()
        effects.shadow = ShadowEffect(angle: .nan, distance: 0, blur: 0, red: 0, green: 0, blue: 0, opacity: 1)
        #expect(!effects.isValid)
        effects.shadow = ShadowEffect(angle: 0, distance: .infinity, blur: 0, red: 0, green: 0, blue: 0, opacity: 1)
        #expect(!effects.isValid)
        effects.shadow = nil
        #expect(effects.isValid)

        var style = LayerShapeStyle(kind: .rectangle, red: 0, green: 0, blue: 0, cornerRadius: .nan)
        #expect(!style.isValid)
        style = LayerShapeStyle(kind: .rectangle, red: 0, green: 0, blue: 0, cornerRadius: -1)
        #expect(!style.isValid)
        style = LayerShapeStyle(kind: .line, red: 0, green: 0, blue: 0, cornerRadius: 0)
        style.lineWidth = 0
        style.start = .zero
        style.end = CGPoint(x: 1, y: 1)
        #expect(!style.isValid)
        style.lineWidth = 2
        #expect(style.isValid)
        style.end = CGPoint(x: 2, y: 1)
        #expect(!style.isValid)
    }
}

/// The modal sheets hold the session's only continuation for a file read. While one is up the
/// session must refuse project operations, history and tab switches, or the sheet's task can be
/// left suspended with nothing left to resume it.
@MainActor
struct ModalSheetGateTests {
    @Test func openSheetsBlockProjectWork() {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        #expect(session.canStartProjectOperation)
        #expect(session.canUseHistory)
        #expect(session.canEditLayers)

        session.showsRawDevelop = true
        #expect(!session.canStartProjectOperation)
        #expect(!session.canUseHistory)
        #expect(!session.canEditLayers)
        session.showsRawDevelop = false

        session.showsPDFImport = true
        #expect(!session.canStartProjectOperation)
        #expect(!session.canUseHistory)
        #expect(!session.canEditLayers)
        session.showsPDFImport = false

        session.showsConversionSheet = true
        #expect(!session.canStartProjectOperation)
        #expect(!session.canUseHistory)
        session.showsConversionSheet = false

        #expect(session.canStartProjectOperation)
    }

    /// A cancelled render never installs an editor, so nothing else would clear the id and the
    /// session would refuse every project operation from then on.
    @Test func cancellingAdjustmentEditLeavesTheSessionUsable() async throws {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)
        session.document?.layers[0].adjustment = LayerAdjustment(kind: .levels)
        session.adjustmentEditingID = id
        #expect(!session.canStartProjectOperation)

        let task = Task { await session.beginAdjustmentEditing(id) }
        task.cancel()
        await task.value
        if session.adjustmentEditingID == id, session.adjustmentOriginal == nil {
            // The render finished before the cancellation landed; finishing by hand is the
            // documented way out, and it must be the only way left.
            _ = session.finishAdjustmentEditing(commit: false)
        }
        #expect(session.adjustmentEditingID == nil)
        #expect(session.canStartProjectOperation)
    }
}
