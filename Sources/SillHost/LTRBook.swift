import Foundation
import os

/// The adaptive encoder's long-term references (RCL): which frame (by its message timestamp) carried
/// which token of which encoder, and which devices said they have it (kind 53). A token is handed to
/// the encoder only once every connected device has acknowledged it, so a refresh from it decodes on
/// every one. The newest 64 references are kept. Any thread.
final class LTRBook: @unchecked Sendable {
    private struct Entry { let serial: Int; let token: Int; var ackers: Set<ObjectIdentifier>; var handed = false }
    private let lock = OSAllocatedUnfairLock()
    private var entries: [Double: Entry] = [:]
    private var order: [Double] = []
    private var acknowledging: Set<ObjectIdentifier> = []

    func note(timestamp: Double, serial: Int, token: Int) {
        lock.withLock {
            entries[timestamp] = Entry(serial: serial, token: token, ackers: [])
            order.append(timestamp)
            if order.count > 64 { entries[order.removeFirst()] = nil }
        }
    }

    /// True the first time `device` acknowledges anything.
    func firstAck(from device: ObjectIdentifier) -> Bool {
        lock.withLock { acknowledging.insert(device).inserted }
    }

    /// `device` has the frame stamped `timestamp`. The token to hand to the running encoder (`serial`)
    /// when that makes every device in `devices` have it, once.
    func ack(timestamp: Double, from device: ObjectIdentifier, serial: Int, devices: Set<ObjectIdentifier>) -> Int? {
        lock.withLock {
            guard var e = entries[timestamp], e.serial == serial else { return nil }
            e.ackers.insert(device)
            var hand: Int?
            if !e.handed, devices.isSubset(of: e.ackers) { e.handed = true; hand = e.token }
            entries[timestamp] = e
            return hand
        }
    }

    func forget(_ device: ObjectIdentifier) {
        lock.withLock { _ = acknowledging.remove(device) }
    }
}
