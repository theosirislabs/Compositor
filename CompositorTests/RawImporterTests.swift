import Foundation
import Testing
@testable import Compositor

@MainActor
struct RawImporterTests {
    @Test func matchesRecognizesCameraRawExtensionsAndRejectsOtherImages() {
        for fileExtension in ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "pef", "srw"] {
            #expect(RawImporter.matches(URL(fileURLWithPath: "/tmp/camera.\(fileExtension)")))
        }
        #expect(RawImporter.matches(URL(fileURLWithPath: "/tmp/camera.DNG")))
        #expect(RawImporter.matches(URL(fileURLWithPath: "/tmp/camera.NEF")))
        for fileExtension in ["jpg", "jpeg", "png", "tif", "tiff", "heic", "pdf"] {
            #expect(!RawImporter.matches(URL(fileURLWithPath: "/tmp/image.\(fileExtension)")))
        }
    }

    /// Whatever `asShot` hands back must be the untouched, identity state — the sheet opens on
    /// the camera's own white balance, and a file with no RAW filter behind it must not shift it.
    @Test func asShotIsAlwaysTheUntouchedState() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("not-here-\(UUID()).dng")
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID()).jpg")
        try? Data("not a camera raw file".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        for url in [missing, junk] {
            guard let settings = RawImporter.asShot(url) else { continue }
            #expect(settings.isAsShot, "\(url.lastPathComponent) should come back untouched")
            #expect(settings.exposure == 0 && settings.boost == 1)
        }
    }
}
