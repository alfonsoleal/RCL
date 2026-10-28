import FileProvider
import UniformTypeIdentifiers
import StreamProtocol

/// One of the Mac's files or folders as Files shows it. Its identifier is its path on the Mac (or
/// "rcl:recents"); the domain's root is the Mac's places (Recents, Desktop, Downloads, Documents,
/// Home), as Get from Mac shows them.
final class FileProviderItem: NSObject, NSFileProviderItem {
    struct Record: Codable, Equatable {
        /// Files' identifier: the path, but for what Recents lists ("RCLRecent|path": the same file
        /// in its own folder is another item, since an item has one parent) and Recents itself.
        var id: String
        var path: String
        var name: String
        var folder: Bool
        var size: Int64?
        var modified: Double?
        /// The identifier of the container it was listed in: Files' parent, the root for a place.
        var parent: String
    }

    let record: Record
    /// The Mac saves into folders (`WindowList.files` 3).
    let writable: Bool

    init(_ record: Record, writable: Bool) {
        self.record = record
        self.writable = writable
    }

    static func root(name: String) -> FileProviderItem {
        FileProviderItem(Record(id: NSFileProviderItemIdentifier.rootContainer.rawValue,
                                path: NSFileProviderItemIdentifier.rootContainer.rawValue, name: name, folder: true,
                                parent: NSFileProviderItemIdentifier.rootContainer.rawValue), writable: false)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(record.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(record.parent) }

    /// Files' identifier for an entry listed in `container` (an identifier).
    static func identifier(path: String, in container: String) -> String {
        if path == "rcl:recents" { return "RCLRecents" }
        return container == "RCLRecents" ? "RCLRecent|\(path)" : path
    }

    var filename: String { record.name }

    var contentType: UTType {
        record.folder ? .folder : (UTType(filenameExtension: (record.name as NSString).pathExtension) ?? .data)
    }

    var documentSize: NSNumber? { record.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { record.modified.map { Date(timeIntervalSince1970: $0) } }

    /// Reading always. Every folder takes new files as far as Files is concerned: a folder without
    /// `.allowsAddingSubItems` is a read-only folder on disk, and Files refused to create one under
    /// the domain's root (cannotSetMetadata, the iPadOS 27 simulator); the places, Recents and a Mac
    /// that can't save are refused in createItem instead, with a reason. A file takes an edit saved
    /// back while the Mac can save it. Nothing is renamed, moved or deleted from here.
    var capabilities: NSFileProviderItemCapabilities {
        if record.folder { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        return writable ? [.allowsReading, .allowsWriting] : [.allowsReading]
    }

    var itemVersion: NSFileProviderItemVersion {
        let v = Data("\(record.size ?? -1)|\(record.modified ?? 0)".utf8)
        return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
    }
}

/// What this domain has listed, kept across the extension's launches (Files asks for an item by
/// identifier long after it listed it): a JSON file per Mac in the extension's own storage.
final class ItemStore {
    private let url: URL
    private let lock = NSLock()
    private var records: [String: FileProviderItem.Record]

    init(directory: URL) {
        url = directory.appendingPathComponent("items.json")
        records = (try? JSONDecoder().decode([String: FileProviderItem.Record].self, from: Data(contentsOf: url))) ?? [:]
    }

    /// By Files' identifier.
    func record(_ id: String) -> FileProviderItem.Record? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    func children(of parent: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { $0.parent == parent }.map(\.id)
    }

    /// A folder's listing: its children now, the ones gone forgotten.
    func replaceChildren(of parent: String, with new: [FileProviderItem.Record]) {
        lock.lock()
        for (k, r) in records where r.parent == parent { records[k] = nil }
        for r in new { records[r.id] = r }
        let snapshot = records
        lock.unlock()
        save(snapshot)
    }

    func remember(_ r: FileProviderItem.Record) {
        lock.lock()
        records[r.id] = r
        let snapshot = records
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: [String: FileProviderItem.Record]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
