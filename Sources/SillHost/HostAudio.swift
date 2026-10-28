import Foundation
import AVFoundation
import Network
import ScreenCaptureKit
import StreamProtocol

/// The Mac's sound for the devices that ask for it (Audio.swift; RCL, Sill's issue #83). Its own
/// ScreenCaptureKit stream, audio only, beside the video's, so the video path is untouched: a
/// window's app's sound for a window, everything but RCL itself for the Desktop. AAC-LC at
/// `MacAudio.bitrate`, sent as kind 41 to the devices that sent kind 42 `on`, and only while one
/// has. A synthetic host plays a quiet tone instead of the Mac's sound (its test pattern's).
@MainActor
final class HostAudio {
    private let server: StreamServer
    private let synthetic: Bool
    /// The devices that want the sound, and whether each has had the encoder's configuration.
    private var wanting: [ObjectIdentifier: (connection: NWConnection, configured: Bool)] = [:]
    /// What the capture follows: the source's filter (nil: nothing streams).
    private var target: SCContentFilter?
    private var targetName = ""
    private var capture: AudioCapture?
    private var tone: SyntheticTone?
    private var encoder: AACEncoder?

    init(server: StreamServer, synthetic: Bool) {
        self.server = server
        self.synthetic = synthetic
    }

    var advertised: Int? { MacAudio.generation }

    // MARK: Devices

    func received(_ payload: Data, from connection: NWConnection, who: String) {
        guard let wanted = Wire.decode(AudioWanted.self, from: payload) else { return }
        let id = ObjectIdentifier(connection)
        if wanted.on {
            guard wanting[id] == nil else { return }
            wanting[id] = (connection, false)
            print("Audio: \(who) plays this Mac's sound.")
        } else {
            guard wanting.removeValue(forKey: id) != nil else { return }
            print("Audio: \(who) stopped playing this Mac's sound.")
        }
        restart()
    }

    func clientLeft(_ connection: NWConnection) {
        guard wanting.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        restart()
    }

    // MARK: The source

    /// What streams now: a window's filter, the Desktop's, or nil. Called by the coordinator each time
    /// a pipeline starts or stops.
    func follow(_ filter: SCContentFilter?, name: String) {
        target = filter
        targetName = name
        restart()
    }

    private func restart() {
        let want = !wanting.isEmpty && (synthetic || target != nil)
        stop()
        guard want else { return }
        do {
            let encoder = try AACEncoder()
            encoder.onConfig = { [weak self] cookie in Task { @MainActor in self?.configChanged(cookie) } }
            encoder.onPacket = { [weak self] packet in Task { @MainActor in self?.send(.packet(packet), configuredOnly: true) } }
            self.encoder = encoder
            if synthetic {
                let tone = SyntheticTone()
                tone.onBuffer = { encoder.encode($0) }
                tone.start()
                self.tone = tone
                print("Audio: a test tone for \(wanting.count) device\(wanting.count == 1 ? "" : "s").")
            } else if let target {
                let capture = AudioCapture()
                capture.onBuffer = { encoder.encode($0) }
                self.capture = capture
                Task { @MainActor in
                    do {
                        try await capture.start(filter: target)
                        print("Audio: capturing \(self.targetName)'s sound for \(self.wanting.count) device\(self.wanting.count == 1 ? "" : "s").")
                    } catch {
                        print("Audio: could not capture \(self.targetName)'s sound: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("Audio: no AAC encoder: \(error.localizedDescription)")
        }
    }

    private func stop() {
        if let capture { Task { await capture.stop() } }
        capture = nil
        tone?.stop()
        tone = nil
        encoder = nil
        for id in wanting.keys { wanting[id]?.configured = false }
    }

    /// A new encoder's configuration: to every device that wants the sound, before its packets.
    private func configChanged(_ cookie: Data) {
        send(.config(cookie), configuredOnly: false)
        for id in wanting.keys { wanting[id]?.configured = true }
    }

    private func send(_ packet: AudioPacket, configuredOnly: Bool) {
        let to = wanting.values.filter { !configuredOnly || $0.configured }.map(\.connection)
        guard !to.isEmpty else { return }
        let message = StreamMessage(kind: .audio, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: packet.encoded())
        server.send(each: to.map { ($0, message) })
        if case .packet = packet { for _ in to { Stats.shared.bump("audio.sent") } }
    }
}

/// An audio-only ScreenCaptureKit stream: the filter's sound as 48 kHz stereo float buffers. The
/// stream still needs a video size, so the smallest, at one frame a second, whose frames are not
/// asked for (no screen output).
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "rcl.audio.capture", qos: .userInteractive)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(MacAudio.sampleRate)
        config.channelCount = MacAudio.channels
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcm(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Audio capture stopped: \(error.localizedDescription)")
    }

    /// The sample buffer's audio as an AVAudioPCMBuffer of its own (copied: SCK reuses its memory).
    static func pcm(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// A synthetic host's sound: a quiet 440 Hz tone, a fifth of a second on and off, so a test hears
/// (and a log shows) packets flowing without this Mac's own sound.
final class SyntheticTone: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rcl.audio.tone")
    private var timer: DispatchSourceTimer?
    private var phase = 0.0
    private var elapsed = 0
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let format = AVAudioFormat(standardFormatWithSampleRate: MacAudio.sampleRate, channels: AVAudioChannelCount(MacAudio.channels))!

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        let frames = AVAudioFrameCount(MacAudio.sampleRate / 50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let on = (elapsed / 10) % 2 == 0
        elapsed += 1
        let step = 2 * Double.pi * 440 / MacAudio.sampleRate
        for i in 0..<Int(frames) {
            let v = on ? Float(sin(phase) * 0.15) : 0
            phase += step
            for c in 0..<Int(format.channelCount) { buffer.floatChannelData![c][i] = v }
        }
        onBuffer?(buffer)
    }
}

/// PCM to AAC-LC packets (1,024 frames each), on a queue of its own. Its magic cookie goes out once
/// it is known, before the first packet.
final class AACEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rcl.audio.encode", qos: .userInteractive)
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var saidCookie = false
    var onConfig: ((Data) -> Void)?
    var onPacket: ((Data) -> Void)?

    init() throws {
        var description = AudioStreamBasicDescription(mSampleRate: MacAudio.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                      mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(MacAudio.channels),
                                                      mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &description) else {
            throw NSError(domain: "RCL", code: 1, userInfo: [NSLocalizedDescriptionKey: "AAC is not available"])
        }
        self.output = output
    }

    func encode(_ buffer: AVAudioPCMBuffer) {
        queue.async { self.encodeNow(buffer) }
    }

    private func encodeNow(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.bitRate = MacAudio.bitrate
            saidCookie = false
        }
        guard let converter else { return }
        pending.append(buffer)
        while true {
            let out = AVAudioCompressedBuffer(format: output, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                guard !self.pending.isEmpty else { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if !saidCookie, let cookie = converter.magicCookie, !cookie.isEmpty {
                saidCookie = true
                onConfig?(cookie)
            }
            if out.packetCount > 0, let descriptions = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descriptions[i]
                    let bytes = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                    if saidCookie { onPacket?(bytes) }
                }
            }
            if status != .haveData || out.packetCount == 0 { break }
        }
    }
}
