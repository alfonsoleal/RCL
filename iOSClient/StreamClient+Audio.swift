import Foundation
import StreamProtocol

// The Mac's sound, this device's side (kind 41 and 42; Audio.swift): ask a Mac that sends audio for
// it while the Mac Sound switch is on (This iPad, on by default), again on a move's new connection,
// and stop asking when the switch goes off. MacAudioPlayer plays it. Main thread, but `macAudio`.
extension StreamClient {
    static let macSoundKey = "Sill.macSound"
    static var macSoundOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: macSoundKey) == nil || defaults.bool(forKey: macSoundKey)
    }

    func hostAudioChanged(_ value: Int?) {
        if hostAudio != value { hostAudio = value }
        updateAudioWanted()
    }

    /// Kind 42 when what this connection asked for changes: on while the Mac sends audio and the
    /// switch is on, off otherwise.
    func updateAudioWanted() {
        let want = (hostAudio ?? 0) >= MacAudio.generation && Self.macSoundOn
        guard want != audioAsked else { return }
        audioAsked = want
        send(.audioWanted, payload: Wire.encode(AudioWanted(on: want)))
        if !want { macAudio.stop() }
        #if DEBUG
        print("audio: " + (want ? "asked the Mac for its sound" : "stopped asking for the Mac's sound"))
        #endif
    }

    func audioMoved() {
        audioAsked = false
        updateAudioWanted()
    }

    func resetAudio() {
        hostAudio = nil
        audioAsked = false
        macAudio.stop()
    }
}
