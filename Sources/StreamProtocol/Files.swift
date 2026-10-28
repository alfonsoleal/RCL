import Foundation

/// Files between the device and the Mac (RCL). A file goes as an offer (kind 43), its bytes in
/// pieces (kind 44) and a done (kind 43); the receiver acknowledges what it has written, so the
/// sender never puts more than `windowBytes` ahead of it on a link the video shares. Both ends run
/// the same `FileTransfers`. A host says it takes files with `WindowList.files`; a device says it
/// takes them with a `ready` (kind 43) once it has seen that.
public enum FileShare {
    public static let generation = 1
    /// `WindowList.files` 2: the host also lists its folders (kinds 46 and 47) and sends a file a
    /// device asks for (a kind 43 `want`), for Get from Mac.
    public static let browseGeneration = 2
    /// `WindowList.files` 3: an offer may name the Mac's folder it goes to (`FileControl.folder`) and
    /// replace a file there (`replace`), for the Files app's location on the device (MacFiles).
    public static let saveGeneration = 3
    /// `WindowList.files` 4: a device's kind 43 `snapshot` asks for a PNG of what streams now, sent to
    /// it as a file named "RCL Screenshot …".
    public static let snapshotGeneration = 4
    /// The start of a screenshot's name, how a device tells one from any other file the Mac sends.
    public static let snapshotPrefix = "RCL Screenshot"
    /// `WindowList.files` 5: an offer may say where on the picture it was dropped (`FileControl.drop`),
    /// and the Mac drags the saved files there, into the app under that point.
    public static let dropGeneration = 5
    /// One piece: well under a host's 1 MiB cap on what a device sends.
    public static let chunkBytes = 256 * 1024
    /// What the sender keeps unacknowledged: about a second of a Low stream on a slow link, a
    /// fraction of one at home, so the video keeps moving while a file goes.
    public static let windowBytes = 2 << 20
    /// The receiver acknowledges at least this often.
    public static let ackBytes = 512 * 1024
    /// Renders and recordings fit; a disk image of a whole drive does not.
    public static let maxFileBytes: Int64 = 16 << 30
    /// Files coming in at once, per connection.
    public static let maxIncoming = 4

    /// A name safe to write anywhere: no folders, no leading dot, nothing a file system refuses,
    /// at most 200 bytes. Never empty.
    public static func safeName(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        var name = last.unicodeScalars.map { s -> String in
            if s == "/" || s == ":" || s == "\\" || s.properties.generalCategory == .control { return "-" }
            return String(s)
        }.joined()
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "File" }
        while name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            guard stem.count > 1 else { name = String(name.prefix(100)); break }
            name = String(stem.dropLast()) + (ext.isEmpty ? "" : "." + ext)
        }
        return name
    }

    /// `name` in `folder`, or "name 2.ext", "name 3.ext"… when it is taken: nothing is overwritten.
    public static func uniqueURL(for name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// "12.3 MB", "640 KB", for every line and label that names a size.
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Kind 43, both ways: one step of a transfer. `offer` (name, size) starts one; `ack` (received) says
/// how much the receiver has written; `done` says every byte went; `saved` (name: where it landed)
/// ends it; `cancel` (note: why) ends it from either side. `ready`, device → host only: this device
/// takes files from the Mac.
public struct FileControl: Codable, Equatable, Sendable {
    public var id: String
    public var op: String
    public var name: String?
    public var size: Int64?
    public var received: Int64?
    public var note: String?
    /// An offer's folder on the receiving side (an absolute path), instead of its usual one; only to
    /// a host whose `WindowList.files` is `saveGeneration`.
    public var folder: String?
    /// An offer's file replaces the one of its name in `folder` (an edit saved back), instead of
    /// landing beside it as "name 2".
    public var replace: Bool?
    /// An offer dropped on the picture; only to a host whose `WindowList.files` is `dropGeneration`.
    public var drop: FileDrop?

    public init(id: String, op: String, name: String? = nil, size: Int64? = nil, received: Int64? = nil, note: String? = nil,
                folder: String? = nil, replace: Bool? = nil, drop: FileDrop? = nil) {
        self.id = id; self.op = op; self.name = name; self.size = size; self.received = received; self.note = note
        self.folder = folder; self.replace = replace; self.drop = drop
    }
}

/// Where files were dropped on the picture: the point as fractions of the frame, and the drop they
/// belong to (one id, how many files), so the Mac drags them together once every one has landed.
public struct FileDrop: Codable, Equatable, Sendable {
    public var group: String
    public var count: Int
    public var x: Double
    public var y: Double

    public init(group: String, count: Int, x: Double, y: Double) {
        self.group = group; self.count = count; self.x = x; self.y = y
    }
}

/// Kind 44, both ways: a piece of a file. The transfer's 16-byte id, its offset (8 bytes, big
/// endian), then the bytes.
public struct FileChunk: Equatable, Sendable {
    public var id: UUID
    public var offset: Int64
    public var data: Data

    public init(id: UUID, offset: Int64, data: Data) { self.id = id; self.offset = offset; self.data = data }

    public func encoded() -> Data {
        var d = Data(capacity: 24 + data.count)
        withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
        d.appendBigEndian(UInt64(bitPattern: offset))
        d.append(data)
        return d
    }

    public static func decode(_ payload: Data) -> FileChunk? {
        guard payload.count > 24 else { return nil }
        var raw = uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &raw) { dst in payload.copyBytes(to: dst, from: payload.startIndex..<(payload.startIndex + 16)) }
        let offset = Int64(bitPattern: payload.readBigEndian(UInt64.self, at: 16))
        return FileChunk(id: UUID(uuid: raw), offset: offset, data: payload.subdata(in: (payload.startIndex + 24)..<payload.endIndex))
    }
}

/// One transfer as the screens show it.
public struct FileTransfer: Equatable, Identifiable, Sendable {
    public enum Direction: Equatable, Sendable { case outgoing, incoming }
    public enum State: Equatable, Sendable {
        case waiting           // outgoing, behind another file
        case moving            // bytes going or coming
        case finished(URL?)    // incoming: where it was saved; outgoing: nil
        case failed(String)
    }
    public var id: String
    public var name: String
    public var size: Int64
    public var done: Int64
    public var direction: Direction
    public var state: State

    public init(id: String, name: String, size: Int64, done: Int64, direction: Direction, state: State) {
        self.id = id; self.name = name; self.size = size; self.done = done; self.direction = direction; self.state = state
    }

    public var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : (state == .moving ? 0 : 1) }
    public var isOver: Bool {
        switch state { case .finished, .failed: return true; default: return false }
    }
}

/// Both ends of every transfer on one connection: what this side sends, one file at a time, and
/// what the other side sends it, written to a temporary file and moved into `folder` once whole.
/// Its own queue; `send` hooks are called on it, `changed` too (hop to the main thread there).
public final class FileTransfers: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rcl.files")
    private let folder: () -> URL
    private let temp: URL

    /// To the other side: a kind 43, a kind 44.
    public var sendControl: ((FileControl) -> Void)?
    public var sendChunk: ((Data) -> Void)?
    /// Whenever a transfer moves on (every ack, the end, a failure).
    public var changed: ((FileTransfer) -> Void)?
    /// Where an offer that names a folder goes, when this side allows that folder; nil refuses it.
    /// Unset: an offer's folder is refused.
    public var destination: ((FileControl) -> URL?)?

    private struct Out {
        var transfer: FileTransfer
        let url: URL
        let release: (() -> Void)?
        var folder: String? = nil
        var replace = false
        var drop: FileDrop? = nil
        var handle: FileHandle?
        var sent: Int64 = 0
        var acked: Int64 = 0
        var doneSent = false
    }
    private struct In {
        var transfer: FileTransfer
        let tempURL: URL
        let handle: FileHandle
        var destination: URL? = nil
        var replace = false
        var lastAck: Int64 = 0
    }
    private var outgoing: [Out] = []
    private var incoming: [String: In] = [:]

    /// `folder`: where finished files go (asked at each save, so a changed choice applies at once).
    /// `temp`: where pieces are written meanwhile.
    public init(folder: @escaping () -> URL, temp: URL) {
        self.folder = folder
        self.temp = temp
    }

    // MARK: Sending

    /// Queues `url` to go to the other side. `release` runs once the file is no longer read (a
    /// security-scoped URL's stopAccessing, a temporary copy's removal). Nil when it cannot be read.
    @discardableResult
    public func send(_ url: URL, name: String? = nil, folder: String? = nil, replace: Bool = false,
                     drop: FileDrop? = nil, release: (() -> Void)? = nil) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let size, size <= FileShare.maxFileBytes else { release?(); return nil }
        let id = UUID().uuidString
        let transfer = FileTransfer(id: id, name: FileShare.safeName(name ?? url.lastPathComponent), size: size, done: 0,
                                    direction: .outgoing, state: .waiting)
        queue.async {
            self.outgoing.append(Out(transfer: transfer, url: url, release: release, folder: folder, replace: replace, drop: drop))
            self.changed?(transfer)
            self.pump()
        }
        return id
    }

    /// The first file in line goes: its offer, then pieces while fewer than `windowBytes` wait
    /// unacknowledged, then its done.
    private func pump() {
        guard var o = outgoing.first else { return }
        if o.transfer.state == .waiting {
            guard let handle = try? FileHandle(forReadingFrom: o.url) else {
                finishOut(.failed("It could not be read."), notify: false)
                return
            }
            o.handle = handle
            o.transfer.state = .moving
            sendControl?(FileControl(id: o.transfer.id, op: "offer", name: o.transfer.name, size: o.transfer.size,
                                     folder: o.folder, replace: o.replace ? true : nil, drop: o.drop))
            changed?(o.transfer)
        }
        guard let uuid = UUID(uuidString: o.transfer.id) else { return }
        while o.sent < o.transfer.size, o.sent - o.acked < Int64(FileShare.windowBytes) {
            let want = Int(min(Int64(FileShare.chunkBytes), o.transfer.size - o.sent))
            guard let data = try? o.handle?.read(upToCount: want), !data.isEmpty else {
                outgoing[0] = o
                finishOut(.failed("It could not be read to the end."), notify: true)
                return
            }
            sendChunk?(FileChunk(id: uuid, offset: o.sent, data: data).encoded())
            o.sent += Int64(data.count)
        }
        if o.sent >= o.transfer.size, !o.doneSent {
            o.doneSent = true
            sendControl?(FileControl(id: o.transfer.id, op: "done", size: o.transfer.size))
        }
        outgoing[0] = o
    }

    private func finishOut(_ state: FileTransfer.State, notify: Bool) {
        guard !outgoing.isEmpty else { return }
        var o = outgoing.removeFirst()
        try? o.handle?.close()
        o.release?()
        if notify, case .failed(let why) = state { sendControl?(FileControl(id: o.transfer.id, op: "cancel", note: why)) }
        o.transfer.state = state
        if case .finished = state { o.transfer.done = o.transfer.size }
        changed?(o.transfer)
        pump()
    }

    // MARK: Receiving

    public func received(control: FileControl) {
        queue.async { self.handle(control) }
    }

    public func received(chunk payload: Data) {
        queue.async { self.handle(chunk: payload) }
    }

    private func handle(_ c: FileControl) {
        switch c.op {
        case "offer":
            // An id is a UUID (it names the piece's file under `temp`), and a few files at a time: each
            // holds a file open and a part on disk (security review, B5 and M3).
            guard incoming[c.id] == nil, UUID(uuidString: c.id) != nil, let size = c.size, size >= 0 else { return }
            let name = FileShare.safeName(c.name ?? "File")
            var t = FileTransfer(id: c.id, name: name, size: size, done: 0, direction: .incoming, state: .moving)
            guard size <= FileShare.maxFileBytes else {
                sendControl?(FileControl(id: c.id, op: "cancel", note: "It is larger than \(FileShare.size(FileShare.maxFileBytes))."))
                t.state = .failed("Too large."); changed?(t); return
            }
            guard incoming.count < FileShare.maxIncoming else {
                sendControl?(FileControl(id: c.id, op: "cancel", note: "Too many files at once. Send it again in a moment."))
                t.state = .failed("Too many at once."); changed?(t); return
            }
            // Room for it and 1 GB more, so a file never fills the disk.
            if let free = (try? temp.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage, free < size + (1 << 30) {
                sendControl?(FileControl(id: c.id, op: "cancel", note: "There is no room for it."))
                t.state = .failed("No room."); changed?(t); return
            }
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let tempURL = temp.appendingPathComponent("rcl-\(c.id).part")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: tempURL) else {
                sendControl?(FileControl(id: c.id, op: "cancel", note: "There is no room for it."))
                t.state = .failed("It could not be written."); changed?(t); return
            }
            var into = In(transfer: t, tempURL: tempURL, handle: handle)
            if c.folder != nil {
                guard let dest = destination?(c) else {
                    try? handle.close(); try? FileManager.default.removeItem(at: tempURL)
                    sendControl?(FileControl(id: c.id, op: "cancel", note: "That folder isn’t available."))
                    t.state = .failed("That folder isn’t available."); changed?(t); return
                }
                into.destination = dest
                into.replace = c.replace == true
            }
            incoming[c.id] = into
            changed?(t)
        case "ack":
            guard let i = outgoing.firstIndex(where: { $0.transfer.id == c.id }), let got = c.received else { return }
            outgoing[i].acked = max(outgoing[i].acked, got)
            outgoing[i].transfer.done = outgoing[i].acked
            changed?(outgoing[i].transfer)
            if i == 0 { pump() }
        case "done":
            guard var i = incoming[c.id] else { return }
            try? i.handle.close()
            incoming[c.id] = nil
            guard i.transfer.done == i.transfer.size else {
                try? FileManager.default.removeItem(at: i.tempURL)
                sendControl?(FileControl(id: c.id, op: "cancel", note: "Bytes went missing on the way."))
                i.transfer.state = .failed("It arrived incomplete."); changed?(i.transfer); return
            }
            let dest = i.destination ?? folder()
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let plain = dest.appendingPathComponent(i.transfer.name)
            let target = i.replace ? plain : FileShare.uniqueURL(for: i.transfer.name, in: dest)
            do {
                if i.replace, FileManager.default.fileExists(atPath: plain.path) {
                    _ = try FileManager.default.replaceItemAt(plain, withItemAt: i.tempURL)
                } else {
                    try FileManager.default.moveItem(at: i.tempURL, to: target)
                }
                sendControl?(FileControl(id: c.id, op: "saved", name: target.lastPathComponent, received: i.transfer.size))
                i.transfer.state = .finished(target)
            } catch {
                try? FileManager.default.removeItem(at: i.tempURL)
                sendControl?(FileControl(id: c.id, op: "cancel", note: "It could not be saved."))
                i.transfer.state = .failed("It could not be saved.")
            }
            changed?(i.transfer)
        case "saved":
            guard outgoing.first?.transfer.id == c.id else { return }
            // The name it landed under ("render 2.mov"), for a sender that tracks where it went.
            if let name = c.name { outgoing[0].transfer.name = name }
            finishOut(.finished(nil), notify: false)
        case "cancel":
            if var i = incoming.removeValue(forKey: c.id) {
                try? i.handle.close()
                try? FileManager.default.removeItem(at: i.tempURL)
                i.transfer.state = .failed(c.note ?? "The other side stopped it.")
                changed?(i.transfer)
            } else if let index = outgoing.firstIndex(where: { $0.transfer.id == c.id }) {
                if index == 0 { finishOut(.failed(c.note ?? "The other side stopped it."), notify: false) }
                else { var o = outgoing.remove(at: index); o.release?(); o.transfer.state = .failed(c.note ?? "Stopped."); changed?(o.transfer) }
            }
        default:
            break
        }
    }

    private func handle(chunk payload: Data) {
        guard let chunk = FileChunk.decode(payload), var i = incoming[chunk.id.uuidString] else { return }
        guard chunk.offset == i.transfer.done, i.transfer.done + Int64(chunk.data.count) <= i.transfer.size else {
            // Out of order or past the end: never on one TCP connection, so a broken sender.
            handle(FileControl(id: i.transfer.id, op: "cancel", note: "Pieces arrived out of order."))
            sendControl?(FileControl(id: i.transfer.id, op: "cancel", note: "Pieces arrived out of order."))
            return
        }
        do { try i.handle.write(contentsOf: chunk.data) } catch {
            incoming[i.transfer.id] = i
            handle(FileControl(id: i.transfer.id, op: "cancel", note: "There is no room for it."))
            sendControl?(FileControl(id: i.transfer.id, op: "cancel", note: "There is no room for it."))
            return
        }
        i.transfer.done += Int64(chunk.data.count)
        if i.transfer.done - i.lastAck >= Int64(FileShare.ackBytes) || i.transfer.done == i.transfer.size {
            i.lastAck = i.transfer.done
            sendControl?(FileControl(id: i.transfer.id, op: "ack", received: i.transfer.done))
            changed?(i.transfer)
        }
        incoming[i.transfer.id] = i
    }

    // MARK: Ending

    /// Stops every transfer of this side (`cancel`, from a person's tap).
    public func cancel(_ id: String) {
        queue.async { self.handle(FileControl(id: id, op: "cancel", note: "Stopped.")); self.sendControl?(FileControl(id: id, op: "cancel", note: "Stopped on the other side.")) }
    }

    /// The connection ended: nothing more arrives, nothing more can go. Partial files are removed.
    public func connectionEnded() {
        queue.async {
            for (_, var i) in self.incoming {
                try? i.handle.close()
                try? FileManager.default.removeItem(at: i.tempURL)
                i.transfer.state = .failed("The connection ended.")
                self.changed?(i.transfer)
            }
            self.incoming = [:]
            for var o in self.outgoing {
                try? o.handle?.close()
                o.release?()
                o.transfer.state = .failed("The connection ended.")
                self.changed?(o.transfer)
            }
            self.outgoing = []
        }
    }
}

/// Kind 46, device → host: list a folder of the Mac's (`path`, absolute), or its places (nil):
/// Recents, Desktop, Downloads, Documents and Home. `token` comes back in the answer.
public struct BrowseRequest: Codable, Equatable, Sendable {
    public var token: Int
    public var path: String?
    public init(token: Int, path: String?) { self.token = token; self.path = path }
}

/// Kind 47, host → device: what one BrowseRequest found. `entries` sorted as the Finder does
/// (folders first, by name; Recents newest first), at most `maxEntries`; `note` says why it is empty
/// or cut short.
public struct BrowseList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var path: String
        public var folder: Bool
        public var size: Int64?
        public var modified: Double?
        public var id: String { path }
        public init(name: String, path: String, folder: Bool, size: Int64? = nil, modified: Double? = nil) {
            self.name = name; self.path = path; self.folder = folder; self.size = size; self.modified = modified
        }
    }
    public static let maxEntries = 500
    public var token: Int
    public var path: String?
    public var title: String
    public var entries: [Entry]
    public var note: String?
    public init(token: Int, path: String?, title: String, entries: [Entry], note: String? = nil) {
        self.token = token; self.path = path; self.title = title; self.entries = entries; self.note = note
    }
}

/// Kind 45, device → host: stream `window` beside the one that streams, the two side by side on the
/// Mac's virtual display (RCL); nil puts it back. Only to a host whose window list says
/// `sideBySide` 1.
public struct SideBySide: Codable, Equatable, Sendable {
    public var window: UInt32?
    public init(window: UInt32?) { self.window = window }
}
