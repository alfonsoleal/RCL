import Foundation

/// The Mac's sound on the device (RCL; Sill's issue #83). The host captures the audio of what
/// streams (a window: its app's; the Desktop: everything but RCL itself), encodes it as AAC-LC and
/// sends it as kind 41 only to the devices that asked with kind 42. A host says it sends audio with
/// `WindowList.audio` (`MacAudio.generation`); a device asks only such a host.
public enum MacAudio {
    public static let generation = 1
    public static let sampleRate = 48_000.0
    public static let channels = 2
    /// AAC-LC, enough for music and a film's voices; a twelfth of a Low stream's video.
    public static let bitrate = 128_000
    /// What a device keeps queued before it drops the oldest: latency beats a gapless sound.
    public static let maxQueuedSeconds = 0.25
}

/// Kind 42, device → host: this device wants the Mac's sound (its Mac Sound switch, while connected
/// to a Mac that sends audio), or no longer does.
public struct AudioWanted: Codable, Equatable, Sendable {
    public var on: Bool
    public init(on: Bool) { self.on = on }
}

/// Kind 41, host → device: the encoder's configuration (the AAC magic cookie, sent to a device first
/// and again whenever the encoder is made anew) or one AAC packet (1,024 frames, ~21 ms).
public enum AudioPacket: Equatable, Sendable {
    case config(Data)
    case packet(Data)

    public func encoded() -> Data {
        switch self {
        case .config(let cookie): return Data([0]) + cookie
        case .packet(let data): return Data([1]) + data
        }
    }

    public static func decode(_ payload: Data) -> AudioPacket? {
        guard let first = payload.first else { return nil }
        let rest = payload.dropFirst()
        switch first {
        case 0: return .config(Data(rest))
        case 1: return rest.isEmpty ? nil : .packet(Data(rest))
        default: return nil
        }
    }
}
