import FileProvider
import StreamProtocol

/// A folder of the Mac's, listed on the Mac each time Files enumerates it or asks what changed (the
/// Mac has no change feed: a visit lists it again). The working set and the trash are empty.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let link: MacLink?
    private let store: ItemStore
    private var task: Task<Void, Never>?

    init(container: NSFileProviderItemIdentifier, link: MacLink?, store: ItemStore) {
        self.container = container
        self.link = link
        self.store = store
    }

    func invalidate() { task?.cancel() }

    private var listsNothing: Bool { container == .workingSet || container == .trashContainer }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if listsNothing { observer.finishEnumerating(upTo: nil); return }
        task = Task {
            do {
                let items = try await list()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if listsNothing { observer.finishEnumeratingChanges(upTo: anchor, moreComing: false); return }
        let before = Set(store.children(of: container.rawValue))
        task = Task {
            do {
                let items = try await list()
                let now = Set(items.map { $0.itemIdentifier.rawValue })
                observer.didUpdate(items)
                let gone = before.subtracting(now).map { NSFileProviderItemIdentifier($0) }
                if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone) }
                observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor())
    }

    private static func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8))
    }

    /// The folder as the Mac lists it now, remembered for Files' later questions. A place listed at
    /// the root (Desktop, Downloads, Documents) is left out of the folder it is in (Home), so each
    /// item has the one parent Files allows.
    private func list() async throws -> [FileProviderItem] {
        guard let link else { throw MacLink.Failure.notPaired }
        let id = container.rawValue
        let path: String? = container == .rootContainer ? nil : (store.record(id)?.path ?? id)
        let listing = try await link.browse(path)
        let writable = link.hostFiles >= FileShare.saveGeneration
        let places = container == .rootContainer ? [] : Set(store.children(of: NSFileProviderItemIdentifier.rootContainer.rawValue))
        let records = listing.entries
            .map {
                FileProviderItem.Record(id: FileProviderItem.identifier(path: $0.path, in: id), path: $0.path, name: $0.name,
                                        folder: $0.folder, size: $0.size, modified: $0.modified, parent: id)
            }
            .filter { !places.contains($0.id) }
        store.replaceChildren(of: id, with: records)
        return records.map { FileProviderItem($0, writable: writable) }
    }
}
