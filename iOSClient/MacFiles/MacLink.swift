import Foundation
import Network
import UIKit
import FileProvider
import StreamProtocol

/// The Files extension's own session with one Mac (RCL), made when Files asks for something and let
/// go after a while with nothing asked: the same TLS session the app opens (pinned to the Mac's
/// key, this device's key from the shared keychain group), its hello first, and then only the files
/// messages: a folder's listing (kinds 46 and 47), a file the Mac sends when asked (kind 43 `want`,
/// then its pieces) and a file saved into a folder of the Mac (an offer naming the folder). It never
/// picks a source, so the Mac captures and encodes nothing for it.
///
/// Where it dials: the Mac's home door where the app last reached it (RCLShared.homeDoors), then the
/// remote door's addresses in the app's order, all at once a short stagger apart (RemoteConnector).
/// Everything on `queue`.
final class MacLink {
    enum Failure: Error {
        case notPaired, unreachable, refused(String), timedOut, tooOld
    }

    let mac: SavedMac
    private let queue = DispatchQueue(label: "rcl.macfiles.link")

    private var connector: RemoteConnector?
    private var connection: NWConnection?
    private var reader: MessageReader?
    /// The Mac's window list arrived: it admitted this device's key.
    private var admitted = false
    private var connectWaiters: [(Result<Void, Failure>) -> Void] = []
    private(set) var hostFiles = 0

    private var token = 1
    private var browses: [Int: (Result<BrowseList, Failure>) -> Void] = [:]
    /// Files asked for, by the name they arrive under (FileShare.safeName).
    private var downloads: [String: [(Result<URL, Failure>) -> Void]] = [:]
    /// Files sent, by transfer id: the name the Mac saved them under.
    private var uploads: [String: (Result<String, Failure>) -> Void] = [:]
    private var idle: DispatchWorkItem?
    private let incoming: URL
    private lazy var engine: FileTransfers = {
        let engine = FileTransfers(folder: { [incoming] in incoming }, temp: incoming.appendingPathComponent(".parts"))
        engine.sendControl = { [weak self] c in self?.queue.async { self?.send(.fileControl, Wire.encode(c)) } }
        engine.sendChunk = { [weak self] data in self?.queue.async { self?.send(.fileChunk, data) } }
        engine.changed = { [weak self] t in self?.queue.async { self?.transferChanged(t) } }
        return engine
    }()

    init(mac: SavedMac, workArea: URL) {
        self.mac = mac
        incoming = workArea.appendingPathComponent("incoming-\(UUID().uuidString)")
    }

    // MARK: What Files asks

    func browse(_ path: String?) async throws -> BrowseList {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<BrowseList, Error>) in
            queue.async {
                self.ready { result in
                    guard case .success = result else { if case .failure(let f) = result { k.resume(throwing: f) }; return }
                    let t = self.token
                    self.token += 1
                    self.browses[t] = { k.resume(with: $0.mapError { $0 as Error }) }
                    self.send(.browse, Wire.encode(BrowseRequest(token: t, path: path)))
                    self.queue.asyncAfter(deadline: .now() + 20) { self.browses.removeValue(forKey: t)?(.failure(.timedOut)) }
                }
            }
        }
    }

    /// The file at `path` on the Mac, in a temporary place of this extension's.
    func download(_ path: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<URL, Error>) in
            queue.async {
                self.ready { result in
                    guard case .success = result else { if case .failure(let f) = result { k.resume(throwing: f) }; return }
                    let name = FileShare.safeName((path as NSString).lastPathComponent)
                    self.downloads[name, default: []].append { k.resume(with: $0.mapError { $0 as Error }) }
                    self.send(.fileControl, Wire.encode(FileControl(id: UUID().uuidString, op: "want", name: path)))
                }
            }
        }
    }

    /// `url` saved as `name` into the Mac's `folder`, replacing a file of that name or beside it;
    /// the name the Mac saved it under.
    func upload(_ url: URL, name: String, folder: String, replace: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
            queue.async {
                self.ready { result in
                    guard case .success = result else { if case .failure(let f) = result { k.resume(throwing: f) }; return }
                    guard self.hostFiles >= FileShare.saveGeneration else { k.resume(throwing: Failure.tooOld); return }
                    guard let id = self.engine.send(url, name: name, folder: folder, replace: replace) else {
                        k.resume(throwing: Failure.refused("It could not be read.")); return
                    }
                    self.uploads[id] = { k.resume(with: $0.mapError { $0 as Error }) }
                }
            }
        }
    }

    func close() { queue.async { self.end(.unreachable) } }

    // MARK: The session

    /// Runs `then` once the Mac has admitted this device, connecting first if need be.
    private func ready(_ then: @escaping (Result<Void, Failure>) -> Void) {
        idle?.cancel()
        if admitted { then(.success(())); scheduleIdle(); return }
        connectWaiters.append { result in then(result); self.scheduleIdle() }
        guard connector == nil, connection == nil else { return }
        guard let identity = DeviceIdentity.existing(), let pin = mac.fingerprintData else { end(.notPaired); return }
        var seen = Set<String>()
        let candidates = (RCLShared.homeDoors(macID: mac.macID)
            + RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked, localIPv4: []))
            .filter { seen.insert($0.key).inserted }
        guard !candidates.isEmpty else { end(.unreachable); return }
        let c = RemoteConnector(candidates: candidates, mode: .session(pin: pin), identity: identity, queue: queue)
        c.onWinner = { [weak self] winner in self?.won(winner.connection) }
        c.onFailed = { [weak self] _ in self?.end(.unreachable) }
        connector = c
        c.start()
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.admitted, !self.connectWaiters.isEmpty else { return }
            self.end(.timedOut)
        }
    }

    private func won(_ c: NWConnection) {
        connector = nil
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, self.connection === c else { return }
            switch state {
            case .failed, .cancelled: self.end(.unreachable)
            default: break
            }
        }
        // The hello first: a Mac judges a device by its first message.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        send(.hello, Wire.encode(Hello(appVersion: version, build: build, protocol: SillProtocol.current,
                                       device: "\(UIDevice.current.name) · Files")))
        let reader = MessageReader(connection: c, stillReads: { [weak self, weak c] in self?.connection === c },
                                   onBytes: { _ in }, onMessage: { [weak self] header, payload in self?.handle(header, payload) },
                                   onEnd: { [weak self] _ in self?.end(.unreachable) })
        self.reader = reader
        reader.start()
    }

    private func handle(_ header: StreamHeader, _ payload: Data) {
        switch header.kind {
        case .windowList:
            hostFiles = Wire.decode(WindowList.self, from: payload)?.files ?? 0
            guard !admitted else { return }
            admitted = true
            let waiting = connectWaiters
            connectWaiters = []
            waiting.forEach { $0(.success(())) }
        case .browseList:
            guard let list = Wire.decode(BrowseList.self, from: payload) else { return }
            browses.removeValue(forKey: list.token)?(.success(list))
        case .fileControl:
            if let c = Wire.decode(FileControl.self, from: payload) { engine.received(control: c) }
        case .fileChunk:
            engine.received(chunk: payload)
        case .goodbye:
            let words = Wire.decode(Goodbye.self, from: payload)?.message
            end(.refused(words ?? "The Mac ended the session."))
        default:
            break   // the catalog, thumbnails and the rest are the app's
        }
    }

    private func transferChanged(_ t: FileTransfer) {
        switch (t.direction, t.state) {
        case (.incoming, .finished(let url?)):
            guard var waiting = downloads[t.name], !waiting.isEmpty else { return }
            let first = waiting.removeFirst()
            downloads[t.name] = waiting.isEmpty ? nil : waiting
            first(.success(url))
        case (.incoming, .failed(let why)):
            downloads.removeValue(forKey: t.name)?.forEach { $0(.failure(.refused(why))) }
        case (.outgoing, .finished):
            uploads.removeValue(forKey: t.id)?(.success(t.name))
        case (.outgoing, .failed(let why)):
            uploads.removeValue(forKey: t.id)?(.failure(.refused(why)))
        default:
            break
        }
    }

    /// Nothing asked for 30 s and nothing moving: the session goes, so the Mac stops sending this
    /// extension its catalog.
    private func scheduleIdle() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.browses.isEmpty, self.downloads.isEmpty, self.uploads.isEmpty else { self?.scheduleIdle(); return }
            self.end(.unreachable)
        }
        idle = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func end(_ why: Failure) {
        idle?.cancel()
        connector?.cancel()
        connector = nil
        if let c = connection {
            connection = nil
            c.stateUpdateHandler = nil
            c.cancel()
            engine.connectionEnded()
        }
        reader = nil
        admitted = false
        let waiting = connectWaiters
        connectWaiters = []
        waiting.forEach { $0(.failure(why)) }
        let b = browses
        browses = [:]
        b.values.forEach { $0(.failure(why)) }
    }

    private func send(_ kind: StreamMessageKind, _ payload: Data) {
        guard let c = connection else { return }
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
        c.send(content: message.serialized(), completion: .contentProcessed { _ in })
    }
}

extension MacLink.Failure {
    /// What Files shows: an unreachable Mac as the system's own "server unreachable".
    var fileProviderError: Error {
        switch self {
        case .notPaired: return NSFileProviderError(.notAuthenticated)
        case .unreachable, .timedOut: return NSFileProviderError(.serverUnreachable)
        case .tooOld: return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                                     userInfo: [NSLocalizedDescriptionKey: "Update RCL on the Mac to save files to it."])
        case .refused(let why): return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                                               userInfo: [NSLocalizedDescriptionKey: why])
        }
    }
}

func fileProviderError(_ error: Error) -> Error {
    (error as? MacLink.Failure)?.fileProviderError ?? error
}
