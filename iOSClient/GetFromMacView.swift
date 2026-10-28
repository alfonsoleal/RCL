import SwiftUI
import PhotosUI
import StreamProtocol

/// Get from Mac: the Mac's places and folders as a native list (kinds 46 and 47), easy on a phone
/// away from home. A folder opens; a file comes down when tapped and lands in RCL's folder, with its
/// progress on its row and in the files chip.
struct GetFromMacView: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MacFolderList(client: client, path: nil)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    if client.macTakesScreenshots {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { client.takeScreenshot(); dismiss() } label: { Label("Screenshot", systemImage: "camera") }
                        }
                    }
                }
        }
        .tint(Palette.accent)
    }
}

private struct MacFolderList: View {
    @ObservedObject var client: StreamClient
    let path: String?
    @State private var list: BrowseList?
    @State private var failed = false
    @State private var asked: Set<String> = []

    var body: some View {
        Group {
            if let list {
                List {
                    ForEach(list.entries) { e in
                        if e.folder {
                            NavigationLink { MacFolderList(client: client, path: e.path) } label: { row(e) }
                        } else {
                            Button { get(e) } label: { row(e) }
                                .buttonStyle(.plain)
                        }
                    }
                    if let note = list.note {
                        Text(note).font(.geist(.footnote)).foregroundStyle(.secondary)
                    }
                }
                .refreshable { await load() }
                .navigationTitle(path == nil && !client.macName.isEmpty ? client.macName : list.title)
            } else if failed {
                ContentUnavailableView("\(client.macName.isEmpty ? "The Mac" : client.macName) Didn’t Answer",
                                       systemImage: "wifi.exclamationmark",
                                       description: Text("Pull down to try again, or check that you’re still connected."))
                    .refreshable { await load() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(path == nil ? .large : .inline)
        .task { if list == nil { await load() } }
    }

    private func load() async {
        let answer = await client.browse(path)
        if let answer { list = answer; failed = false } else if list == nil { failed = true }
    }

    private func get(_ e: BrowseList.Entry) {
        guard !asked.contains(e.path) else { return }
        asked.insert(e.path)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.want(e.path)
    }

    private func row(_ e: BrowseList.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(e))
                .font(.geist(.title3))
                .foregroundStyle(e.folder ? Palette.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.geist(.body)).lineLimit(1).truncationMode(.middle)
                if let detail = detail(e) {
                    Text(detail).font(.geist(.caption)).foregroundStyle(.secondary)
                }
                if let t = transfer(e), case .moving = t.state {
                    ProgressView(value: t.fraction).tint(Palette.accent)
                }
            }
            Spacer(minLength: 0)
            if !e.folder { status(e) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(e.folder ? String(localized: "Opens the folder") : String(localized: "Downloads it to this \(StreamClient.deviceWord)"))
    }

    @ViewBuilder private func status(_ e: BrowseList.Entry) -> some View {
        switch transfer(e)?.state {
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .moving, .waiting: EmptyView()
        case nil:
            Image(systemName: asked.contains(e.path) ? "hourglass" : "arrow.down.circle")
                .foregroundStyle(asked.contains(e.path) ? Color.secondary : Palette.accent)
        }
    }

    /// This file's transfer, matched by name among what came lately.
    private func transfer(_ e: BrowseList.Entry) -> FileTransfer? {
        guard asked.contains(e.path) else { return nil }
        return client.fileTransfers.first { $0.direction == .incoming && $0.name == FileShare.safeName(e.name) }
    }

    private func detail(_ e: BrowseList.Entry) -> String? {
        var parts: [String] = []
        if let size = e.size { parts.append(FileShare.size(size)) }
        if let m = e.modified {
            parts.append(Date(timeIntervalSince1970: m).formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func symbol(_ e: BrowseList.Entry) -> String {
        if e.path == "rcl:recents" { return "clock" }
        if e.folder {
            switch e.name { case "Desktop": return "menubar.dock.rectangle"; case "Downloads": return "arrow.down.circle"
            case "Documents": return "doc"; case "Home": return "house"; default: return "folder" }
        }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v": return "film"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "dmg": return "doc.zipper"
        case "mp3", "wav", "m4a", "aif", "aiff": return "waveform"
        default: return "doc"
        }
    }
}

/// The Mac's files without its picture (the connect screen's folder button): its places and folders,
/// sending from this device, the files chip, and the way to the picture or out. Nothing streams
/// meanwhile (StreamClient.filesOnly), so the Mac captures and encodes nothing.
struct FilesHome: View {
    @ObservedObject var client: StreamClient
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if client.macListsFiles {
                    MacFolderList(client: client, path: nil)
                } else {
                    ContentUnavailableView("Connecting…", systemImage: "folder", description: Text("Waiting for \(client.macName.isEmpty ? "the Mac" : client.macName) to list its files."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Disconnect") { client.disconnect() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { client.viewMacFromFiles() } label: { Label("View Mac", systemImage: "desktopcomputer") }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { importing = true } label: { Label("Send Files", systemImage: "doc.badge.arrow.up") }
                        .disabled(!client.macTakesFiles)
                    Spacer()
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                        Label("Send Photos", systemImage: "photo.badge.arrow.down")
                    }
                    .disabled(!client.macTakesFiles)
                }
            }
        }
        .tint(Palette.accent)
        .overlay(alignment: .bottom) {
            if !client.fileTransfers.isEmpty {
                FilesChip(client: client).padding(.horizontal, 12).padding(.bottom, 56)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            client.sendFiles(urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                return (url, scoped ? { url.stopAccessingSecurityScopedResource() } : nil)
            })
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items {
                Task {
                    guard let picked = try? await item.loadTransferable(type: PickedFile.self) else { return }
                    client.sendFiles([(picked.url, { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) })])
                }
            }
        }
    }
}

/// The bars' Files button (RCL, in Aa's place): Get from Mac in a sheet. Dimmed while the Mac lists
/// no files (a Mac from before it, or still connecting).
struct FilesBarButton: View {
    @ObservedObject var client: StreamClient
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 16
    var iconSize: CGFloat = 22
    /// Under the symbol, as the bars' other buttons; the compact dock shows symbols alone.
    var labelled = true
    @State private var showing = false

    var body: some View {
        BarButton(open: showing, width: width, height: height, radius: radius,
                  accessibilityLabel: String(localized: "Files on \(client.macName.isEmpty ? "the Mac" : client.macName)"),
                  action: { showing = true }) {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down.doc")
                    .font(.geist(iconSize))
                    .foregroundStyle(showing ? Palette.accent : Palette.text)
                if labelled {
                    Text("Files")
                        .font(.geist(11, .medium))
                        .foregroundStyle(showing ? Palette.accent : Palette.barLabel)
                }
            }
        }
        .opacity(client.macListsFiles ? 1 : 0.4)
        .disabled(!client.macListsFiles)
        .sheet(isPresented: $showing) { GetFromMacView(client: client) }
        .onChange(of: showing) { _, now in client.filesSheetOpen = now }
    }
}
