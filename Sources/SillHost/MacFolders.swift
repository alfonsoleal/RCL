import Foundation
import StreamProtocol

/// Get from Mac (kinds 46 and 47): what a device sees of this Mac's folders. Only inside `root` (the
/// person's home; a synthetic host's test folder), never a hidden file, never through a link that
/// leads out of it, and never the home's Library or Applications: what apps keep there (cookies,
/// tokens, launch agents) is no document, and a file put in ~/Library/LaunchAgents runs at the next
/// login. The coordinator also refuses all of it while the Mac is locked (security review, A1).
struct MacFolders {
    let root: URL

    /// The places, then any folder: an answer for `request`.
    func list(_ request: BrowseRequest) -> BrowseList {
        guard let path = request.path else { return places(token: request.token) }
        if path == Self.recentsPath { return recents(token: request.token) }
        guard let url = inside(path) else {
            return BrowseList(token: request.token, path: path, title: "Not Available", entries: [], note: "Only folders inside your home folder are shown.")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return BrowseList(token: request.token, path: path, title: url.lastPathComponent, entries: [],
                              note: "This Mac didn’t let RCL read this folder. Allow RCL in System Settings › Privacy & Security › Files and Folders.")
        }
        var entries = items.compactMap(entry)
        entries.sort { a, b in a.folder != b.folder ? a.folder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let cut = entries.count > BrowseList.maxEntries
        return BrowseList(token: request.token, path: url.path, title: url.path == root.path ? "Home" : url.lastPathComponent,
                          entries: Array(entries.prefix(BrowseList.maxEntries)),
                          note: cut ? "Showing the first \(BrowseList.maxEntries) of \(entries.count)." : (entries.isEmpty ? "This folder is empty." : nil))
    }

    /// The file a device asks for, when it is one this listing would show.
    func file(_ path: String) -> URL? {
        guard let url = inside(path) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    /// A folder a device may save into (an offer's `folder`), when this listing would show it.
    func folder(_ path: String) -> URL? {
        guard let url = inside(path) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    static let recentsPath = "rcl:recents"
    /// The home's folders a device never reads or writes (lowercased: the disk ignores case).
    static let offLimits: Set<String> = ["library", "applications"]

    // MARK: Inside

    private func places(token: Int) -> BrowseList {
        var entries = [BrowseList.Entry(name: "Recents", path: Self.recentsPath, folder: true)]
        for name in ["Desktop", "Downloads", "Documents"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { entries.append(BrowseList.Entry(name: name, path: url.path, folder: true)) }
        }
        entries.append(BrowseList.Entry(name: "Home", path: root.path, folder: true))
        return BrowseList(token: token, path: nil, title: "Places", entries: entries)
    }

    /// Files changed in the last 14 days in Desktop, Downloads and Documents (and a folder below each),
    /// newest first, at most 60: where a render or a download lands.
    private func recents(token: Int) -> BrowseList {
        let since = Date().addingTimeInterval(-14 * 86_400)
        var found: [BrowseList.Entry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        for name in ["Desktop", "Downloads", "Documents"] {
            let base = root.appendingPathComponent(name)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level > 2 { walker.skipDescendants(); continue }
                guard let e = entry(url), !e.folder, let m = e.modified, m >= since.timeIntervalSince1970 else { continue }
                found.append(e)
                if found.count > 2_000 { break }
            }
        }
        found.sort { ($0.modified ?? 0) > ($1.modified ?? 0) }
        return BrowseList(token: token, path: Self.recentsPath, title: "Recents", entries: Array(found.prefix(60)),
                          note: found.isEmpty ? "Nothing changed in the last two weeks in Desktop, Downloads or Documents." : nil)
    }

    private func entry(_ url: URL) -> BrowseList.Entry? {
        // A link is shown as what it leads to, and only when that is inside the root too.
        guard let real = inside(url.path) else { return nil }
        let v = try? real.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey])
        // A package (an app, a Final Cut library) is one thing to the person, but it is a folder that
        // cannot go as one file: shown as a folder to look into, as the Finder's Show Package Contents.
        let folder = v?.isDirectory ?? false
        return BrowseList.Entry(name: url.lastPathComponent, path: url.path, folder: folder,
                                size: folder ? nil : v?.fileSize.map(Int64.init), modified: v?.contentModificationDate?.timeIntervalSince1970)
    }

    /// `path` resolved (links followed), when it is `root` or below it.
    private func inside(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        let parts = url.path.dropFirst(base.count).split(separator: "/")
        let hidden = parts.contains { $0.hasPrefix(".") }
        let kept = parts.first.map { Self.offLimits.contains($0.lowercased()) } ?? false
        return hidden || kept ? nil : url
    }
}
