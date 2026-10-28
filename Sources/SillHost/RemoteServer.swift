import Foundation
import Network
import StreamProtocol

/// The remote door (docs/remote-access-plan.md §4.7): a TLS 1.3 listener on a fixed port, for
/// paired devices only, running while Remote Access is on or a pairing window it takes proofs for
/// is open (one the Mac's user opened, never one a device opened by asking at home). Both sides
/// present self-signed P-256 certificates and pin each other's key (RemoteTLS). No Bonjour.
///
/// This type keeps the listener's life: the port (never another one by itself), the 30 s retry,
/// and its log lines. Admission is `Door(.remote)`, the same code the home door runs once it
/// speaks TLS (docs/home-pairing-plan.md §4.4), with DoorPolicy's remote rules: paired keys while
/// Remote Access is on, 8 sessions at most, pairing only for a remote window, and an ask answered
/// `closed`.
///
/// Threading: everything here runs on StreamServer's network queue, which the listener, the
/// connections, their verify blocks and the timers share. Callbacks out are on that queue.
///
/// TEST ONLY: StreamServer's SILL_TEST_LOOPBACK=1 puts this listener on 127.0.0.1 alone too, on a
/// test host.
final class RemoteServer {
    static let retryInterval: TimeInterval = 30

    private let queue: DispatchQueue
    private unowned let server: StreamServer
    private let trust: TrustBox
    private let door: Door

    /// The listener's port and state are called back on the network queue.
    var onListener: ((RemoteStatus.Listener) -> Void)?
    /// A pairing attempt at this door; the reply may be called from any thread.
    var onPairAttempt: ((Door.PairAttempt, @escaping @Sendable (PairResult) -> Void) -> Void)? {
        get { door.onPairAttempt }
        set { door.onPairAttempt = newValue }
    }

    // On `queue`.
    private var listener: NWListener?
    /// The same door over QUIC (RCL), on the TCP listener's port number, UDP: a device that tries
    /// QUIC first gets it, any other the TCP door as before. Its failure never stops the TCP door.
    private var quicListener: NWListener?
    private var wanted = false
    private var port = HostConfig.defaultRemotePort
    private var retryItem: DispatchWorkItem?
    private var reportedFailure = false

    init(server: StreamServer, identity: HostIdentity, trust: TrustBox) {
        self.server = server
        queue = server.queue
        self.trust = trust
        door = Door(.remote, queue: server.queue, identity: identity, trust: trust, testHost: server.isTestHost)
        door.server = server
    }

    // MARK: The listener

    /// Runs the door on `port` (0: any free port) while `wanted`. A new port replaces the listener
    /// (accepted connections are independent of it, so sessions carry on). Thread-safe.
    func set(wanted: Bool, port: Int) {
        queue.async { [self] in
            let portChanged = port != self.port
            self.wanted = wanted
            self.port = port
            guard wanted else {
                stopListener()
                onListener?(.off)
                return
            }
            if listener != nil, !portChanged { return }
            stopListener()
            startListener()
        }
    }

    /// A network change: if the door should run and does not (the port was in use), try now.
    func retryNow() {
        queue.async { [self] in
            if wanted, listener == nil { startListener() }
        }
    }

    private func stopListener() {
        retryItem?.cancel(); retryItem = nil
        listener?.cancel()
        listener = nil
        quicListener?.cancel()
        quicListener = nil
    }

    private func startQUIC(on bound: Int) {
        quicListener?.cancel()
        quicListener = nil
        guard let p = NWEndpoint.Port(rawValue: UInt16(bound)) else { return }
        let params = door.quicParameters()
        let q: NWListener
        do {
            if server.loopbackOnly {   // TEST ONLY: SILL_TEST_LOOPBACK (StreamServer)
                StreamServer.bindToLoopback(params, port: p)
                q = try NWListener(using: params)
            } else {
                q = try NWListener(using: params, on: p)
            }
        } catch {
            print("Remote access: QUIC couldn’t start on port \(bound) (\(error)); TCP only.")
            return
        }
        quicListener = q
        // Each QUIC stream arrives as a connection; a device opens one, the session.
        q.newConnectionHandler = { [weak self, weak q] c in
            guard let self, let q, q === self.quicListener else { c.cancel(); return }
            self.door.accept(c)
        }
        q.stateUpdateHandler = { [weak self, weak q] state in
            guard let self, let q, q === self.quicListener else { return }
            switch state {
            case .ready: print("Remote access: QUIC on port \(bound) too (UDP).")
            case .failed(let e):
                print("Remote access: QUIC stopped (\(e)); TCP only.")
                q.cancel()
                self.quicListener = nil
            default: break
            }
        }
        q.start(queue: queue)
    }

    private func startListener() {
        retryItem?.cancel(); retryItem = nil
        let params = RemoteTLS.parameters(tls: door.tlsOptions(), dialing: false)
        let l: NWListener
        do {
            if port == 0 {
                if server.loopbackOnly { StreamServer.bindToLoopback(params, port: nil) }   // TEST ONLY
                l = try NWListener(using: params)
            } else {
                guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { failed(.posix(.EINVAL)); return }
                if server.loopbackOnly {   // TEST ONLY: SILL_TEST_LOOPBACK (StreamServer)
                    StreamServer.bindToLoopback(params, port: p)
                    l = try NWListener(using: params)
                } else {
                    l = try NWListener(using: params, on: p)
                }
            }
        } catch {
            failed(error as? NWError ?? .posix(.EINVAL))
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self, weak l] c in
            guard let self, let l, l === self.listener else { c.cancel(); return }
            self.door.accept(c)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                let bound = Int(l.port?.rawValue ?? 0)
                reportedFailure = false
                print("Remote access: listening on port \(bound) (TLS, paired devices only; \(trust.snapshot.paired.count) paired).")
                onListener?(.listening(bound))
                startQUIC(on: bound)
            case .failed(let e):
                l.cancel()
                listener = nil
                failed(e)
            case .waiting(let e):
                if case .posix(.EADDRINUSE) = e {
                    l.cancel()
                    listener = nil
                    failed(e)
                }
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    /// Never another port by itself: saved addresses depend on this one. Retried every 30 s and
    /// on network changes; the door never exits the process.
    private func failed(_ e: NWError) {
        if case .posix(.EADDRINUSE) = e {
            if !reportedFailure { print("Remote access: port \(port) is in use by another app; trying again every 30 s.") }
            onListener?(.portInUse(port))
        } else {
            if !reportedFailure { print("Remote access couldn’t start (\(e)); trying again every 30 s.") }
            onListener?(.failed("\(e)"))
        }
        reportedFailure = true
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, self.listener == nil else { return }
            self.startListener()
        }
        retryItem = item
        queue.asyncAfter(deadline: .now() + Self.retryInterval, execute: item)
    }

    // MARK: Closing sessions

    /// Every admitted remote session whose route matches gets goodbye `reason` and is closed; `line`
    /// names one (from its paired name and endpoint) for the log, and `done` gets how many there
    /// were. Home sessions are never touched here (Remote Access and its internet switch are about
    /// who reaches the Mac from away). Thread-safe.
    func closeSessions(_ reason: String, matching: @escaping @Sendable (ClientRoute) -> Bool,
                       line: (@Sendable (String, String) -> String)? = nil, done: (@Sendable (Int) -> Void)? = nil) {
        server.closeSessions(reason, matching: { $0.isRemote && matching($0) }, line: line, done: done)
    }
}
