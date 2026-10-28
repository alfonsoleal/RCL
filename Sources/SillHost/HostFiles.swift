import Foundation
import Network
import StreamProtocol

/// Files, the Mac's side (kinds 43 and 44; Files.swift). What a device sends lands in the Downloads
/// folder ("render.mov", "render 2.mov" when taken); the Mac sends a file to every device that said
/// `ready` (the menu's Send File…, or a file dropped on the menu bar icon). One `FileTransfers` per
/// connection. One line per file, never its contents.
///
/// A synthetic host never writes to this Mac's Downloads: it saves to the folder TEST ONLY
/// `SILL_TEST_FILES_DIR` names, or a temporary one, and says which at start.
@MainActor
final class HostFiles {
    private let server: StreamServer
    private let status: HostStatus
    private let folder: URL
    let testHookLine: String?
    private var transfers: [ObjectIdentifier: (connection: NWConnection, engine: FileTransfers, who: String, ready: Bool)] = [:]
    private var shown: [FileTransfer] = []
    private var browsing: [ObjectIdentifier: Int] = [:]
    /// TEST ONLY (`SILL_TEST_SEND_FILE`, a synthetic host): sent to each device as it says `ready`.
    private let testSend: URL?

    var advertised: Int? { FileShare.dropGeneration }
    /// Whether the Mac's screen is locked: then a device may still send a file to Downloads, but not
    /// look through the Mac's folders, ask for one of its files or save into a folder of its choice
    /// (security review, A1: locked, typing reaches nothing, files would).
    var isLocked: () -> Bool = { false }
    /// Files dropped on the picture, saved: the coordinator drags them to their point.
    var onDrop: (_ urls: [URL], _ drop: FileDrop, _ who: String) -> Void = { _, _, _ in }
    /// Dropped transfers by their id, and each drop's files as they land (nil: one that failed).
    private var dropOf: [String: FileDrop] = [:]
    private var dropped: [String: [URL?]] = [:]
    /// Get from Mac: the home folder, or a synthetic host's test folder.
    private let folders: MacFolders

    init(server: StreamServer, status: HostStatus, synthetic: Bool, environment env: [String: String] = ProcessInfo.processInfo.environment) {
        self.server = server
        self.status = status
        if synthetic {
            let dir = env["SILL_TEST_FILES_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("rcl-files-\(getpid())")
            folder = dir
            folders = MacFolders(root: env["SILL_TEST_BROWSE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? dir)
            testSend = env["SILL_TEST_SEND_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            testHookLine = "Test files: what devices send is saved to \(dir.path), never Downloads"
                + (testSend.map { "; \($0.lastPathComponent) goes to each device that says ready." } ?? ".")
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            testSend = nil
            testHookLine = nil
            folders = MacFolders(root: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    // MARK: Devices

    func received(control payload: Data, from connection: NWConnection, who: String) {
        guard let c = Wire.decode(FileControl.self, from: payload) else { return }
        let t = entry(for: connection, who: who)
        if c.op == "ready" {
            guard !t.ready else { return }
            transfers[ObjectIdentifier(connection)]?.ready = true
            publish()
            if let testSend { t.engine.send(testSend) }
            return
        }
        if c.op == "want" {
            // Get from Mac: a file the device picked in a listing, sent as Send File… sends it.
            if isLocked() {
                t.engine.sendControl?(FileControl(id: c.id, op: "cancel", note: "Unlock the Mac to get its files."))
                return
            }
            guard let path = c.name, let url = folders.file(path) else {
                t.engine.sendControl?(FileControl(id: c.id, op: "cancel", note: "That file isn’t available."))
                return
            }
            print("Files: \(who) asked for \(url.lastPathComponent).")
            t.engine.send(url)
            return
        }
        if c.op == "offer", c.folder != nil, isLocked() {
            t.engine.sendControl?(FileControl(id: c.id, op: "cancel", note: "Unlock the Mac to save into its folders."))
            return
        }
        if c.op == "offer", let drop = c.drop, drop.count > 0, drop.count <= 100 { dropOf[c.id] = drop }
        t.engine.received(control: c)
    }

    /// Get from Mac: a folder's listing, or the places, read off the main actor (a big folder takes a
    /// moment), to that device alone.
    func browse(_ payload: Data, from connection: NWConnection) {
        guard let r = Wire.decode(BrowseRequest.self, from: payload) else { return }
        if isLocked() {
            let list = BrowseList(token: r.token, path: r.path, title: "Locked", entries: [], note: "Unlock the Mac to see its files.")
            server.send(StreamMessage(kind: .browseList, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                      payload: Wire.encode(list)), to: connection)
            return
        }
        // At most four listings at once per device (the Files app asks for a few together); past that
        // the device hears to try again, rather than every request reading the disk at once.
        let id = ObjectIdentifier(connection)
        guard browsing[id, default: 0] < 4 else {
            let list = BrowseList(token: r.token, path: r.path, title: "Busy", entries: [], note: "The Mac is busy. Try again.")
            server.send(StreamMessage(kind: .browseList, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                      payload: Wire.encode(list)), to: connection)
            return
        }
        browsing[id, default: 0] += 1
        let folders = folders
        let done: @MainActor () -> Void = { [weak self] in self?.browsing[id, default: 1] -= 1 }
        Task.detached { [weak server, weak connection] in
            let list = folders.list(r)
            await done()
            guard let server, let connection else { return }
            server.send(StreamMessage(kind: .browseList, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                      payload: Wire.encode(list)), to: connection)
        }
    }

    func received(chunk payload: Data, from connection: NWConnection, who: String) {
        entry(for: connection, who: who).engine.received(chunk: payload)
    }

    func clientLeft(_ connection: NWConnection) {
        browsing[ObjectIdentifier(connection)] = nil
        guard let t = transfers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        t.engine.connectionEnded()
        publish()
    }

    /// Devices that take files from this Mac, by name, for the menu.
    var readyDevices: [String] { transfers.values.filter(\.ready).map(\.who).sorted() }

    // MARK: The Mac sends

    /// `urls` to every device that said `ready`. False when none has.
    @discardableResult
    func send(_ urls: [URL]) -> Bool {
        let targets = transfers.values.filter(\.ready)
        guard !targets.isEmpty else { return false }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                print("Files: \(url.lastPathComponent) is a folder; only files are sent.")
                continue
            }
            for t in targets { t.engine.send(url) }
        }
        return true
    }

    // MARK: Inside

    private func entry(for connection: NWConnection, who: String) -> (connection: NWConnection, engine: FileTransfers, who: String, ready: Bool) {
        let id = ObjectIdentifier(connection)
        if let t = transfers[id] { return t }
        let engine = FileTransfers(folder: { [folder] in folder },
                                   temp: FileManager.default.temporaryDirectory.appendingPathComponent("rcl-incoming"))
        engine.sendControl = { [weak server, weak connection] c in
            guard let server, let connection else { return }
            server.send(StreamMessage(kind: .fileControl, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                      payload: Wire.encode(c)), to: connection)
        }
        engine.sendChunk = { [weak server, weak connection] data in
            guard let server, let connection else { return }
            server.send(StreamMessage(kind: .fileChunk, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: data),
                        to: connection)
            Stats.shared.bump("file.sent")
        }
        engine.changed = { [weak self] t in Task { @MainActor in self?.changed(t, who: who) } }
        // The Files app's Mac location (MacFiles) saves into a folder of the home, never elsewhere.
        let folders = folders
        engine.destination = { c in c.folder.flatMap { folders.folder($0) } }
        let t = (connection, engine, who, false)
        transfers[id] = t
        return t
    }

    private func changed(_ t: FileTransfer, who: String) {
        if t.direction == .incoming, t.isOver, let drop = dropOf.removeValue(forKey: t.id) {
            var landed = dropped[drop.group] ?? []
            if case .finished(let url?) = t.state { landed.append(url) } else { landed.append(nil) }
            dropped[drop.group] = landed
            if landed.count >= drop.count {
                dropped[drop.group] = nil
                let urls = landed.compactMap { $0 }
                if !urls.isEmpty { onDrop(urls, drop, who) }
            }
        }
        if let i = shown.firstIndex(where: { $0.id == t.id }) { shown[i] = t } else { shown.insert(t, at: 0) }
        if shown.count > 5 { shown.removeLast(shown.count - 5) }
        switch (t.direction, t.state) {
        case (.incoming, .finished(let url?)):
            print("Files: \(t.name) (\(FileShare.size(t.size))) from \(who), saved to \(url.path).")
        case (.outgoing, .finished):
            print("Files: \(t.name) (\(FileShare.size(t.size))) sent to \(who).")
        case (.incoming, .failed(let why)):
            print("Files: \(t.name) from \(who) did not arrive: \(why)")
        case (.outgoing, .failed(let why)):
            print("Files: \(t.name) did not reach \(who): \(why)")
        default: break
        }
        publish()
    }

    /// A file to one device (a screenshot it asked for); `release` once it has been read.
    func send(_ url: URL, to connection: NWConnection, who: String, release: (() -> Void)? = nil) {
        entry(for: connection, who: who).engine.send(url, release: release)
    }

    private func publish() {
        let ready = transfers.values.filter(\.ready).count
        let files = shown
        status.update { $0.fileDevices = ready; $0.files = files }
    }
}
