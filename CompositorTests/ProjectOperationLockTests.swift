import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// The project-operation lock is a counter, not a flag. Operations used to set `isProjectBusy` on
/// the way in and clear it on the way out; two that overlapped let the first release the second's
/// hold, and a third — a Save, say — then started while a brush commit was still writing.
@MainActor
struct ProjectOperationLockTests {
    @Test func overlappingOperationsKeepTheLockUntilTheLastOneFinishes() {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        #expect(!session.isProjectBusy)

        session.beginProjectOperation()
        #expect(session.isProjectBusy)
        session.beginProjectOperation()
        #expect(session.isProjectBusy)

        session.endProjectOperation()
        #expect(session.isProjectBusy, "the first one out must not release the second's hold")
        session.endProjectOperation()
        #expect(!session.isProjectBusy)
    }

    @Test func anExtraReleaseCannotDriveTheCountNegative() {
        let session = EditorSession()
        session.beginProjectOperation()
        session.endProjectOperation()
        session.endProjectOperation()
        #expect(!session.isProjectBusy)
        // Still usable afterwards: a real operation acquires normally.
        session.beginProjectOperation()
        #expect(session.isProjectBusy)
        session.endProjectOperation()
    }

    /// A filter commit that starts while something else holds the lock still applies, and the
    /// count returns to zero — the commit takes the lock itself and gives it back.
    @Test func aFilterCommitOverlappingAnotherOperationStillApplies() async throws {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let before = try #require(session.activeLayer?.asset?.image)

        session.beginFilter(.exposure)
        var settings = try #require(session.filterEdit).settings
        settings.exposure = ExposureSettings(exposure: 1.5)
        session.filterEdit?.settings = settings
        session.beginProjectOperation()          // e.g. a Save already under way
        await session.commitFilter()
        session.endProjectOperation()

        #expect(session.activeLayer?.asset?.image !== before, "the adjustment should have landed")
        #expect(!session.isProjectBusy, "both operations should have given the lock back")
        #expect(session.filterEdit == nil)
    }

    /// The lock also gates what the interface will let the user start, so a sheet that opens during
    /// a long operation is refused rather than queued behind it.
    @Test func theGateFollowsTheCount() {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        #expect(session.canStartProjectOperation)
        session.beginProjectOperation()
        #expect(!session.canStartProjectOperation)
        session.endProjectOperation()
        #expect(session.canStartProjectOperation)
    }
}
