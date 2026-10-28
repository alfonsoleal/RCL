import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import StreamProtocol

// Files, this device's side (kinds 43 and 44; Files.swift). What the Mac sends lands in RCL's own
// folder, which the Files app shows (On My iPad › RCL); this device sends what is picked in Settings,
// dropped on the picture or shared to RCL from another app. One engine; a connection's transfers end
// with it (a move to another path ends them too: the Mac keeps them per connection). Main thread,
// but the engine, which runs on its own queue.
extension StreamClient {
    /// RCL's Documents folder: the Files app lists it (UIFileSharingEnabled).
    static var receivedFilesFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The window list's word: say `ready` once per connection, and send what waited for a Mac.
    func hostFilesChanged(_ value: Int?) {
        if hostFiles != value { hostFiles = value }
        wireFileEngine()
        guard (value ?? 0) >= FileShare.generation, !filesReadySent else { return }
        filesReadySent = true
        send(.fileControl, payload: Wire.encode(FileControl(id: "", op: "ready")))
        let waiting = filesWaiting
        filesWaiting = []
        for f in waiting { _ = fileEngine.send(f.url, release: f.release) }
        #if DEBUG
        // Harness: `-SillSendFile <path>` sends that file (a path on this Mac, which the simulator
        // reads) once the Mac takes files.
        if let path = UserDefaults.standard.string(forKey: "SillSendFile"), !path.isEmpty {
            // `-SillDropAt x,y`: as if dropped there on the picture (fractions of the frame).
            let at = UserDefaults.standard.string(forKey: "SillDropAt")?.split(separator: ",").compactMap { Double($0) }
            let drop = at.flatMap { $0.count == 2 && (value ?? 0) >= FileShare.dropGeneration
                ? FileDrop(group: UUID().uuidString, count: 1, x: $0[0], y: $0[1]) : nil }
            // A drop waits for the picture, as a person's does.
            DispatchQueue.main.asyncAfter(deadline: .now() + (drop == nil ? 0 : 6)) { [weak self] in
                self?.sendFiles([(URL(fileURLWithPath: path), nil)], drop: drop)
            }
        }
        // `-SillScreenshotAt <s>`: a screenshot s seconds after the Mac said it takes files.
        let at = UserDefaults.standard.double(forKey: "SillScreenshotAt")
        if at > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.takeScreenshot() } }
        #endif
    }

    /// Whether this session's Mac takes files.
    var macTakesFiles: Bool { (hostFiles ?? 0) >= FileShare.generation }

    /// Files to the Mac. `release` runs once each is read (a security-scoped URL's end, a temporary
    /// copy's removal). Without a Mac that takes them they wait for the next session.
    func sendFiles(_ files: [(url: URL, release: (() -> Void)?)], drop: FileDrop? = nil) {
        noteAction()
        guard macTakesFiles else { filesWaiting += files; return }
        for f in files {
            if fileEngine.send(f.url, drop: drop, release: f.release) == nil {
                note(FileTransfer(id: UUID().uuidString, name: f.url.lastPathComponent, size: 0, done: 0,
                                  direction: .outgoing, state: .failed(String(localized: "It could not be read, or it is larger than \(FileShare.size(FileShare.maxFileBytes))."))))
            }
        }
    }

    /// A file URL from another app (Share › RCL, Open In): its own access for as long as it is read.
    func sendOpenedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        sendFiles([(url, scoped ? { url.stopAccessingSecurityScopedResource() } : nil)])
    }

    /// Files dropped on the picture or picked in Photos: each copied out of its provider (whose file
    /// goes when the load returns) into a temporary folder, removed once sent. Dropped on the picture
    /// (`at`, a fraction of the frame) to a Mac that takes it, they go as one drop: the Mac drags them
    /// to that point once all have landed, so the count is of the files that could be read.
    func dropFiles(_ providers: [NSItemProvider], at point: (x: Double, y: Double)? = nil) {
        let group = DispatchGroup()
        var copies: [URL] = []
        let lock = NSLock()
        for provider in providers {
            let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
                ?? provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                if let url, let copy = Self.temporaryCopy(of: url, named: provider.suggestedName) {
                    lock.lock(); copies.append(copy); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !copies.isEmpty else { return }
            let drop = point.flatMap { p in
                (self.hostFiles ?? 0) >= FileShare.dropGeneration
                    ? FileDrop(group: UUID().uuidString, count: copies.count, x: p.x, y: p.y) : nil
            }
            self.sendFiles(copies.map { copy in (copy, { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }) },
                           drop: drop)
        }
    }

    /// A copy of `url` in a folder of its own under tmp, named `name` (with `url`'s extension when
    /// `name` has none) or as `url` is.
    static func temporaryCopy(of url: URL, named name: String?) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing-\(UUID().uuidString)")
        var file = name.map(FileShare.safeName) ?? url.lastPathComponent
        if (file as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { file += ".\(url.pathExtension)" }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(file)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch { return nil }
    }

    func dismissFile(_ id: String) {
        if let t = fileTransfers.first(where: { $0.id == id }), !t.isOver { fileEngine.cancel(id) }
        fileTransfers.removeAll { $0.id == id }
    }

    // MARK: Screenshots (a kind 43 `snapshot`)

    /// The Mac takes screenshots for a device (files generation 4).
    var macTakesScreenshots: Bool { (hostFiles ?? 0) >= FileShare.snapshotGeneration }

    /// Asks the Mac for a PNG of what streams now, at its full size; it lands in Photos (and in RCL's
    /// folder, as any file from the Mac).
    func takeScreenshot() {
        guard macTakesScreenshots else { showScreenshotNote(String(localized: "Update RCL on \(macName.isEmpty ? "the Mac" : macName) to take screenshots.")); return }
        noteAction()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        send(.fileControl, payload: Wire.encode(FileControl(id: UUID().uuidString, op: "snapshot")))
    }

    /// Into Photos with add-only access (the system asks once). Refused: it stays in RCL's folder.
    private func saveScreenshot(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.showScreenshotNote(String(localized: "Screenshot saved in Files, On My \(Self.deviceWord), RCL. Allow Photos for RCL to save it there.")) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async {
                    self.showScreenshotNote(ok ? String(localized: "Screenshot saved to Photos") : String(localized: "Screenshot saved in Files, On My \(Self.deviceWord), RCL."))
                    if ok { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
        }
    }

    func showScreenshotNote(_ note: String) {
        screenshotNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.screenshotNote == note { self?.screenshotNote = nil }
        }
    }

    func filesMoved() {
        fileEngine.connectionEnded()
        filesReadySent = false
        hostFilesChanged(hostFiles)
    }

    func resetFiles() {
        for (_, c) in browseWaits { c.resume(returning: nil) }
        browseWaits = [:]
        fileEngine.connectionEnded()
        filesReadySent = false
        hostFiles = nil
        hostSideBySide = nil
        beside = nil
    }

    // MARK: Get from Mac (kinds 46 and 47, a kind 43 `want`)

    /// The Mac lists its folders and sends a file asked for.
    var macListsFiles: Bool { (hostFiles ?? 0) >= FileShare.browseGeneration }

    /// One of the Mac's folders (nil: its places), or nil when it did not answer in 10 s.
    func browse(_ path: String?) async -> BrowseList? {
        browseToken += 1
        let token = browseToken
        send(.browse, payload: Wire.encode(BrowseRequest(token: token, path: path)))
        return await withCheckedContinuation { c in
            browseWaits[token] = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.browseWaits.removeValue(forKey: token)?.resume(returning: nil)
            }
        }
    }

    /// A file of the Mac's, by its path in a listing: the Mac sends it (it arrives as any file does).
    func want(_ path: String) {
        noteAction()
        send(.fileControl, payload: Wire.encode(FileControl(id: UUID().uuidString, op: "want", name: path)))
    }

        // MARK: Files alone (the connect screen)

    /// Connects to `mac` for its files: no picture is asked for, so the Mac captures and encodes nothing.
    func connectForFiles(to mac: FoundMac) {
        filesOnly = true
        connect(to: mac)
    }

    /// From the files to the Mac's picture: the Desktop, as a connection starts.
    func viewMacFromFiles() {
        filesOnly = false
        select(.desktop)
    }

    // MARK: Side by side (kind 45)

    /// `window` beside the one that streams, or nil for one window again.
    func setBeside(_ window: UInt32?) {
        noteAction()
        send(.sideBySide, payload: Wire.encode(SideBySide(window: window)))
    }

    // MARK: Inside

    private func wireFileEngine() {
        guard fileEngine.sendControl == nil else { return }
        fileEngine.sendControl = { [weak self] c in self?.send(.fileControl, payload: Wire.encode(c)) }
        fileEngine.sendChunk = { [weak self] d in self?.send(.fileChunk, payload: d) }
        fileEngine.changed = { [weak self] t in DispatchQueue.main.async { self?.note(t) } }
    }

    private func note(_ t: FileTransfer) {
        if let i = fileTransfers.firstIndex(where: { $0.id == t.id }) { fileTransfers[i] = t } else { fileTransfers.insert(t, at: 0) }
        if fileTransfers.count > 4 { fileTransfers.removeLast(fileTransfers.count - 4) }
        // A file that went out leaves the chip by itself; one that came in stays until it is opened
        // or dismissed, so it can be found.
        if t.direction == .outgoing, t.isOver {
            let id = t.id
            let failed: Bool = { if case .failed = t.state { return true } else { return false } }()
            DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 3)) { [weak self] in
                self?.fileTransfers.removeAll { $0.id == id && $0.isOver }
            }
        }
        if t.direction == .incoming, case .finished(let url?) = t.state, t.name.hasPrefix(FileShare.snapshotPrefix) {
            saveScreenshot(url)
        }
        #if DEBUG
        switch t.state {
        case .finished(let url): print("files: \(t.name) \(t.direction == .incoming ? "saved to \(url?.lastPathComponent ?? "?")" : "sent")")
        case .failed(let why): print("files: \(t.name) failed: \(why)")
        default: break
        }
        #endif
    }
}
