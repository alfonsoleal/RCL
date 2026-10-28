import FileProvider
import StreamProtocol

/// The Files app's location for one paired Mac (RCL): a domain per Mac, named after it, added by the
/// app (MacFilesDomains). Its folders are the Mac's, listed on demand; a file comes down when opened;
/// a file saved into one of the Mac's folders, or an edit saved back, goes to the Mac. Nothing of the
/// Mac's is renamed, moved or deleted from here.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let mac: SavedMac?
    private let link: MacLink?
    private let store: ItemStore

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let mac = RCLShared.savedMacs().first { $0.macID == domain.identifier.rawValue }
        self.mac = mac
        let work = (NSFileProviderManager(for: domain).flatMap { try? $0.temporaryDirectoryURL() })
            ?? FileManager.default.temporaryDirectory
        let storage = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RCLShared.appGroup)?
            .appendingPathComponent("MacFiles/\(domain.identifier.rawValue)") ?? work
        store = ItemStore(directory: storage)
        link = mac.map { MacLink(mac: $0, workArea: work) }
        super.init()
    }

    func invalidate() { link?.close() }

    private var writable: Bool { (link?.hostFiles ?? 0) >= FileShare.saveGeneration }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root(name: mac?.name ?? domain.displayName), nil)
        } else if let r = store.record(identifier.rawValue) {
            completionHandler(FileProviderItem(r, writable: writable), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let link, let r = store.record(itemIdentifier.rawValue), !r.folder else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return progress
        }
        Task {
            do {
                let url = try await link.download(r.path)
                progress.completedUnitCount = 1
                completionHandler(url, FileProviderItem(r, writable: writable), nil)
            } catch {
                completionHandler(nil, nil, fileProviderError(error))
            }
        }
        return progress
    }

    /// A file saved into a folder of the Mac's: it goes there, beside a file of the same name rather
    /// than over it ("name 2"), as the Mac's Downloads takes what a device sends.
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let parent = itemTemplate.parentItemIdentifier
        guard let link, let url, let folder = store.record(parent.rawValue), folder.folder,
              folder.path != "rcl:recents", parent != .rootContainer, itemTemplate.contentType != .folder else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                                                      userInfo: [NSLocalizedDescriptionKey: "Save into one of the Mac’s folders."]))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let saved = try await link.upload(url, name: itemTemplate.filename, folder: folder.path, replace: false)
                let path = (folder.path as NSString).appendingPathComponent(saved)
                let record = FileProviderItem.Record(id: path, path: path, name: saved,
                                                     folder: false, size: itemTemplate.documentSize??.int64Value,
                                                     modified: Date().timeIntervalSince1970, parent: parent.rawValue)
                store.remember(record)
                progress.completedUnitCount = 1
                completionHandler(FileProviderItem(record, writable: true), [], false, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    /// An edit saved back: the new contents replace the Mac's file. A rename or a move is refused.
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let link, var r = store.record(item.itemIdentifier.rawValue) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem)); return Progress()
        }
        guard changedFields.contains(.contents), let newContents else {
            // Dates and the like: nothing to tell the Mac.
            completionHandler(FileProviderItem(r, writable: writable), [], false, nil)
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                _ = try await link.upload(newContents, name: r.name, folder: (r.path as NSString).deletingLastPathComponent, replace: true)
                r.size = item.documentSize??.int64Value ?? r.size
                r.modified = Date().timeIntervalSince1970
                store.remember(r)
                progress.completedUnitCount = 1
                completionHandler(FileProviderItem(r, writable: true), [], false, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSFileProviderError(.deletionRejected))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(container: containerItemIdentifier, link: link, store: store)
    }
}
