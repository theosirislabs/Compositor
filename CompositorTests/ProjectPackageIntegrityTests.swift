import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// A project package is written and read by code that has to trust nothing in it: the manifest
/// names the files, and those files sit in a directory the user can swap for a symlink. These are
/// the cases where a careless save or a tampered package used to succeed anyway.
@MainActor
struct ProjectPackageIntegrityTests {
    /// A document with a real image layer, so the package it saves has an asset in it.
    private func painted() async throws -> ProjectSnapshot {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        return try #require(session.projectSnapshot())
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A save whose assets would not fit the per-file ceiling the reader enforces must be refused
    /// at save time: a project that saves and then will not open is worse than one that refuses.
    @Test func savingRespectsThePerAssetCeilingTheReaderEnforces() async throws {
        let snapshot = try await painted()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Project.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        // A package saved within the limits reopens.
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.width == snapshot.manifest.width)
    }

    /// The reader checks a path and then reopens it by name, which left a window in which the file
    /// could be replaced. A symlink where an asset should be is refused, not followed.
    @Test func anAssetThatIsASymlinkIsRefused() async throws {
        let snapshot = try await painted()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Project.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let target = try #require(FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("images").path).first)
        let asset = url.appendingPathComponent("images").appendingPathComponent(target)
        let secret = root.appendingPathComponent("secret.png")
        try Data("not a png at all".utf8).write(to: secret)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: secret)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: url) }
    }

    /// A drop the app had to copy gets its copy removed once the import is done, whether it worked
    /// or not; a user's own file in any other place is never touched.
    @Test func temporaryDropCopiesAreRemovedAfterImport() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent("Dropped").appendingPathExtension("png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try ImageImportTests().fixture(.png), to: copy)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = EditorSession()
        await session.importImages([copy])
        #expect(session.document?.layers.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the temporary copy should be gone")

        // A file in any other folder is left exactly where it is, even inside the temporary
        // directory: only a bare UUID folder is ours.
        let keepFolder = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keepFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keepFolder) }
        let elsewhere = keepFolder.appendingPathComponent("keep.png")
        try FileManager.default.copyItem(at: try ImageImportTests().fixture(.png), to: elsewhere)
        ImageFileDrop.discardTemporaryCopy(of: elsewhere)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}
