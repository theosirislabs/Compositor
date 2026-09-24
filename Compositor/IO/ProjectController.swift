import AppKit
import UniformTypeIdentifiers
import SwiftUI

private final class SheetRequest<Output>: @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let continuation: CheckedContinuation<Output?, Never>
        let cleanup: () -> Void
    }

    private let lock = NSLock()
    private var cancelled = false
    private var pending: Pending?
    private var observers: [NSObjectProtocol] = []

    @discardableResult
    func resume(_ output: Output?) -> Output? {
        guard let pending = takePending() else { return nil }
        finish(pending, output: output)
        return output
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = pending
        let observers = observers
        self.pending = nil
        self.observers.removeAll()
        lock.unlock()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let pending { finish(pending, output: nil) }
    }

    func start(
        continuation: CheckedContinuation<Output?, Never>,
        observers: [NSObjectProtocol],
        cleanup: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            finish(Pending(continuation: continuation, cleanup: cleanup), output: nil)
            return false
        }
        pending = Pending(continuation: continuation, cleanup: cleanup)
        self.observers = observers
        lock.unlock()
        return true
    }

    func isPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    private func takePending() -> Pending? {
        lock.lock()
        let pending = pending
        let observers = observers
        self.pending = nil
        self.observers.removeAll()
        lock.unlock()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        return pending
    }

    private func finish(_ pending: Pending, output: Output?) {
        if Thread.isMainThread { pending.cleanup() }
        else { DispatchQueue.main.async { pending.cleanup() } }
        pending.continuation.resume(returning: output)
    }
}

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    private var saveGeneration = 0
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    private func awaitSheet<Output>(
        on window: NSWindow,
        sheet: NSWindow,
        content: (@escaping (Output?) -> Void) -> Void
    ) async -> Output? {
        let request = SheetRequest<Output>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [request] notification in
                    guard let closing = notification.object as? NSWindow, closing === window else { return }
                    request.cancel()
                }
                let terminateObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { [request] _ in request.cancel() }
                guard request.start(
                    continuation: continuation,
                    observers: [closeObserver, terminateObserver],
                    cleanup: {
                        if window.attachedSheet === sheet { window.endSheet(sheet) }
                        sheet.orderOut(nil)
                        sheet.contentViewController = nil
                    }
                ) else { return }
                content { output in _ = request.resume(output) }
                if request.isPending() { window.beginSheet(sheet) }
            }
        } onCancel: {
            request.cancel()
        }
    }

    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard session.document != nil, begin() else { return false }
        defer { session.isProjectBusy = false }
        return await saveCurrent(asNew: asNew)
    }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await ImageExporter.shared.exportPNG(snapshot, to: url) }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let sheet = NSWindow()
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.title = "Canvas Size"
        let options: CanvasSizeOptions? = await awaitSheet(on: window, sheet: sheet) { completion in
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, foreground: session.foregroundColor, background: session.backgroundColor) { completion($0) })
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            session.applyDocumentSize(resized, actionName: "Canvas Size")
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let sheet = NSWindow()
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.title = "Image Size"
        let options: ImageSizeOptions? = await awaitSheet(on: window, sheet: sheet) { completion in
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { completion($0) })
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            session.applyImageSize(resized)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let sheet = NSWindow()
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.title = "Trim"
        let options: TrimOptions? = await awaitSheet(on: window, sheet: sheet) { completion in
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { completion($0) })
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            session.applyDocumentSize(resized, actionName: "Trim")
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Export JPEG"
            let data: Data? = await awaitSheet(on: window, sheet: sheet) { completion in
                sheet.contentViewController = NSHostingController(rootView: JPEGExportSheet(raster: raster) { completion($0) })
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(data, to: url)
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard let snapshot = session.projectSnapshot() else { return true }
        var destination = asNew ? nil : session.projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.comp"
            panel.title = asNew ? "Save Project As" : "Save Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await ProjectStore.shared.save(snapshot, to: destination)
            session.projectURL = destination
            session.history.markSaved()
            saveGeneration += 1
            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            return true
        } catch {
            await showError("Couldn’t save the project", error: error)
            return false
        }
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Open Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
            }
            session.installProject(snapshot, from: source)
            NSDocumentController.shared.noteNewRecentDocumentURL(source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject() }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed {
            session.clearProject()
            window.close()
        }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    private func showError(_ title: String, error: Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}
