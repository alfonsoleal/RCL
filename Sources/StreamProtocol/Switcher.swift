import Foundation

/// What the host streams. The client decides; the host only ever streams one source.
public enum StreamSource: Codable, Hashable {
    case none
    case window(UInt32)   // CGWindowID, stable for the life of the window
    case desktop          // the Mac's main display
}

/// One on-screen Mac window, as the client sees it. WindowList order is stable: first seen first.
public struct WindowInfo: Codable, Hashable, Identifiable {
    public var id: UInt32
    public var title: String
    public var appName: String
    public var bundleID: String
    public var width: Int      // points
    public var height: Int

    public init(id: UInt32, title: String, appName: String, bundleID: String, width: Int, height: Int) {
        self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.width = width; self.height = height
    }
}

/// An installed app, for the drawer's "All apps" section.
public struct AppInfo: Codable, Hashable, Identifiable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}

public struct WindowList: Codable {
    public var macName: String
    public var windows: [WindowInfo]
    public var active: StreamSource
    /// Random, picked once per launch of the host and the same in every list to every device: two
    /// connections whose lists carry the same one reach the same running host. A name cannot tell
    /// that (two Macs can share one, and mDNS renames neither when they share no link), and a
    /// device moving its session from AWDL to the network must not land on another Mac. Optional:
    /// nil from a host older than 2026-09-24, and an older device ignores the key.
    public var launchID: String?
    /// The host's version: Sill.app's CFBundleShortVersionString ("0.4.0"); nil from SillHost (no
    /// bundle) and from hosts before 2026-09-25. For later devices: which Mac to update, and to what
    /// (docs/update-notice-plan.md §14).
    public var hostVersion: String?
    /// The host's SillProtocol.current; nil from hosts before 2026-09-25, which speak 1. The JSON key
    /// is "protocol".
    public var `protocol`: Int?
    /// Which trackpad gestures this host takes (kind 28, Gesture.swift): 1 is the six of
    /// `TrackpadGesture.names`, each turned into the Mac's own shortcut. Nil from every host before
    /// 2026-09-27, to which a device sends no kind 28. A later generation of gestures says 2 and
    /// goes only to a host that says so.
    public var gestures: Int?
    /// What this host takes and sends of the clipboard (kind 32, Clipboard.swift): 1 is text
    /// (`ClipboardPolicy.generation`). Nil from every host before 2026-10-14, and from one whose Share
    /// clipboard with devices is off: a device sends no kind 32 to either. A later generation
    /// (images) says 2, and a device sends images only to a host that says so. An Int, as `gestures`:
    /// pull request #66's `Bool` (never released) does not decode here and becomes an Int as it
    /// rebases.
    public var clipboard: Int?
    /// The Mac's displays the Desktop can stream (#91, #139), in the Mac's arrangement from left to
    /// right; nil from a host that streams only one (Sill), and to such a host a device sends no
    /// kind 40. Never the virtual display a window is staged on.
    public var displays: [DisplayInfo]?
    /// Which of `displays` the Desktop streams now.
    public var desktopDisplay: UInt32?
    /// The host sends the Mac's sound to a device that asks (`MacAudio.generation`); nil: it sends none.
    public var audio: Int?
    /// The host takes and sends files (kinds 43 and 44, `FileShare.generation`); nil: it does neither.
    public var files: Int?
    /// The host can stream two windows side by side (kind 45); nil: it cannot (the CLI without
    /// --virtual-display, a host without the virtual display).
    public var sideBySide: Int?
    /// The window that streams beside `active` now; nil: none.
    public var beside: UInt32?
    /// The host takes kind 48 (TrackpadMotion.generation); nil: it does not.
    public var trackpadMotion: Int?
    /// The host takes kind 49 (AppCommand.generation); nil: it does not.
    public var appCommands: Int?
    /// The host blanks its own screens for a device (kind 50, PrivacyMode.generation); nil: it does not.
    public var privacy: Int?
    /// Its screens are blanked now (some connected device asked).
    public var privacyOn: Bool?
    /// The Mac's screen is locked (RCL): a device offers to type its password. Nil: the host doesn't say.
    public var locked: Bool?

    public init(macName: String, windows: [WindowInfo], active: StreamSource, launchID: String? = nil,
                hostVersion: String? = nil, protocol: Int? = nil, gestures: Int? = nil, clipboard: Int? = nil,
                displays: [DisplayInfo]? = nil, desktopDisplay: UInt32? = nil, audio: Int? = nil,
                files: Int? = nil, sideBySide: Int? = nil, beside: UInt32? = nil, trackpadMotion: Int? = nil,
                appCommands: Int? = nil, privacy: Int? = nil, privacyOn: Bool? = nil, locked: Bool? = nil) {
        self.macName = macName; self.windows = windows; self.active = active; self.launchID = launchID
        self.hostVersion = hostVersion; self.protocol = `protocol`; self.gestures = gestures
        self.clipboard = clipboard; self.displays = displays; self.desktopDisplay = desktopDisplay; self.audio = audio
        self.files = files; self.sideBySide = sideBySide; self.beside = beside; self.trackpadMotion = trackpadMotion
        self.appCommands = appCommands
        self.privacy = privacy; self.privacyOn = privacyOn; self.locked = locked
    }
}

/// One of the Mac's displays, as the device's Desktop button names it (#91, #139).
public struct DisplayInfo: Codable, Hashable, Identifiable {
    /// The CGDirectDisplayID, stable while the display stays connected.
    public var id: UInt32
    /// macOS's name for it ("Built-in Retina Display", "LG UltraFine").
    public var name: String
    public var width: Int      // points
    public var height: Int
    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
}

/// Kind 40, device → host: stream this display as the Desktop.
public struct DesktopDisplay: Codable, Equatable {
    public var id: UInt32
    public init(id: UInt32) { self.id = id }
}

public struct LaunchApp: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// Client → host: what the bar's long-press menu asks of a window, the three traffic lights.
/// Kind 49, device → host (RCL): Quit for a window's app, from a thumbnail's held lights; `action`
/// "quit" (a polite quit: the app may ask to save) or "hide". Only to a host whose window list says
/// `appCommands` 1.
public struct AppCommand: Codable, Equatable, Sendable {
    public static let generation = 1
    public var bundleID: String
    public var action: String
    public init(bundleID: String, action: String) { self.bundleID = bundleID; self.action = action }
}

/// Kind 50, device → host (RCL): Private Mode, this device's wish that the Mac's own screens show
/// black while it works on them (a curtain only the Mac's screens show, never a stream). The host
/// blanks them while any connected device wishes it, and never once none is left.
public struct PrivacyMode: Codable, Equatable, Sendable {
    public static let generation = 1
    public var on: Bool
    public init(on: Bool) { self.on = on }
}

public struct WindowCommand: Codable {
    public enum Action: String, Codable { case close, minimize, fullScreen }
    public var id: UInt32
    public var action: Action
    public init(id: UInt32, action: Action) { self.id = id; self.action = action }
}

/// JSON payloads. Everything here is small and infrequent; frames never go through JSON.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// Binary image payloads: a key, then the image bytes.
public enum ImageBlob {
    /// windowID(4, BE) + JPEG
    public static func encodeThumbnail(windowID: UInt32, jpeg: Data) -> Data {
        var d = Data(capacity: 4 + jpeg.count)
        d.appendBigEndian(windowID)
        d.append(jpeg)
        return d
    }
    public static func decodeThumbnail(_ d: Data) -> (windowID: UInt32, jpeg: Data)? {
        guard d.count > 4 else { return nil }
        return (d.readBigEndian(UInt32.self, at: 0), d.subdata(in: (d.startIndex + 4)..<d.endIndex))
    }

    /// bundleIDLength(2, BE) + bundleID UTF-8 + PNG
    public static func encodeIcon(bundleID: String, png: Data) -> Data {
        let id = Data(bundleID.utf8)
        var d = Data(capacity: 2 + id.count + png.count)
        d.appendBigEndian(UInt16(id.count))
        d.append(id)
        d.append(png)
        return d
    }
    public static func decodeIcon(_ d: Data) -> (bundleID: String, png: Data)? {
        guard d.count > 2 else { return nil }
        let len = Int(d.readBigEndian(UInt16.self, at: 0))
        guard d.count > 2 + len else { return nil }
        let idStart = d.startIndex + 2
        guard let id = String(data: d.subdata(in: idStart..<(idStart + len)), encoding: .utf8) else { return nil }
        return (id, d.subdata(in: (idStart + len)..<d.endIndex))
    }
}
