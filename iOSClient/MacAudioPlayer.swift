import Foundation
import AVFoundation
import StreamProtocol

/// The Mac's sound on this device (kind 41; Audio.swift): AAC-LC packets decoded and played at once
/// through an AVAudioEngine, with at most `MacAudio.maxQueuedSeconds` waiting (more and the oldest
/// is dropped: the sound keeps up with the picture rather than lag behind it). Thread-safe: packets
/// come on the client's network queue, everything here runs on its own queue.
final class MacAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rcl.audio.play", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm = AVAudioFormat(standardFormatWithSampleRate: MacAudio.sampleRate, channels: AVAudioChannelCount(MacAudio.channels))!
    private var input: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Seconds of sound scheduled and not yet played.
    private var queued = 0.0
    private var started = false
    private var dropped = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
    }

    func receive(_ payload: Data) {
        queue.async { self.handle(payload) }
    }

    /// The session ended or the switch went off: silence, and the next configuration starts afresh.
    func stop() {
        queue.async {
            self.player.stop()
            self.engine.stop()
            self.started = false
            self.queued = 0
            self.converter = nil
            self.input = nil
        }
    }

    private func handle(_ payload: Data) {
        switch AudioPacket.decode(payload) {
        case .config(let cookie)?:
            var description = AudioStreamBasicDescription(mSampleRate: MacAudio.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                          mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                          mBytesPerFrame: 0, mChannelsPerFrame: UInt32(MacAudio.channels),
                                                          mBitsPerChannel: 0, mReserved: 0)
            guard let format = AVAudioFormat(streamDescription: &description) else { return }
            format.magicCookie = cookie
            input = format
            converter = AVAudioConverter(from: format, to: pcm)
            converter?.magicCookie = cookie
            startIfNeeded()
        case .packet(let data)?:
            play(data)
        case nil:
            break
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        // Playback: heard with the ring switch on silent, as a video app's sound is; mixed with what
        // else plays, since RCL is a window onto the Mac, not the device's main audio.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        do {
            try engine.start()
            player.play()
            started = true
            #if DEBUG
            print("audio: playing the Mac's sound")
            #endif
        } catch {
            print("audio: could not start: \(error.localizedDescription)")
        }
    }

    private func play(_ data: Data) {
        guard let input, let converter, started else { return }
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: data.count)
        data.withUnsafeBytes { raw in packet.data.copyMemory(from: raw.baseAddress!, byteCount: data.count) }
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(data.count))
        packet.packetCount = 1
        packet.byteLength = UInt32(data.count)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return packet
        }
        guard out.frameLength > 0 else { return }
        let seconds = Double(out.frameLength) / MacAudio.sampleRate
        // Behind by more than the most it may wait: drop this one, so the sound catches up.
        guard queued + seconds <= MacAudio.maxQueuedSeconds else {
            dropped += 1
            #if DEBUG
            if dropped % 50 == 1 { print("audio: \(dropped) packets dropped to keep up") }
            #endif
            return
        }
        queued += seconds
        player.scheduleBuffer(out) { [weak self] in
            self?.queue.async { self?.queued = max(0, (self?.queued ?? 0) - seconds) }
        }
    }
}
