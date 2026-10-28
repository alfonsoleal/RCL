import AppIntents
import Foundation
import StreamProtocol

// Siri and Shortcuts (RCL): what a person asks of RCL without opening it first — connect to a Mac,
// show its Desktop, open one of its apps, Private Mode, a screenshot. Each opens RCL (the stream is
// the app's) and acts on its one StreamClient. The widgets and the Control Center control reach the
// same through `rcl://` links (handleOpenURL), since an extension can't hold a session.

/// A paired Mac, as Shortcuts lists them (RCLShared's copy of the saved list).
struct MacEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mac"
    static let defaultQuery = MacQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "macbook"))
    }
}

struct MacQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MacEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MacEntity] { all() }

    private func all() -> [MacEntity] {
        let macs = RCLShared.savedMacs()
        let names = SavedMacs.displayNames(macs)
        return macs.map { MacEntity(id: $0.macID, name: names[$0.macID] ?? $0.name) }
    }
}

/// The app's StreamClient once it exists (an intent can run while RCL is still launching).
@MainActor
private func client() async throws -> StreamClient {
    for _ in 0..<40 {
        if let c = StreamClient.current { return c }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw IntentError.notReady
}

/// A session with the Mac, waited for up to `seconds` (a connect just asked for, or one under way).
@MainActor
private func connected(_ c: StreamClient, within seconds: Double = 12) async throws {
    for _ in 0..<Int(seconds * 10) {
        if c.connected { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw IntentError.notConnected
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, notConnected, noSuchApp

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "RCL didn’t open in time. Try again."
        case .notConnected: "RCL isn’t connected to a Mac. Connect first, then try again."
        case .noSuchApp: "That app isn’t on the Mac."
        }
    }
}

struct ConnectToMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Mac"
    static let description = IntentDescription("Opens RCL and connects to a paired Mac.")
    static let openAppWhenRun = true

    @Parameter(title: "Mac") var mac: MacEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = try await client()
        let target = mac?.id ?? RCLShared.lastMacID() ?? RCLShared.savedMacs().first?.macID
        c.connectSaved(macID: target)
        return .result()
    }
}

struct ShowMacDesktopIntent: AppIntent {
    static let title: LocalizedStringResource = "Show the Mac’s Desktop"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = try await client()
        try await connected(c)
        c.select(.desktop)
        return .result()
    }
}

struct OpenMacAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open an App on the Mac"
    static let openAppWhenRun = true

    @Parameter(title: "App", requestValueDialog: "Which app?") var app: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = try await client()
        try await connected(c)
        let wanted = app.trimmingCharacters(in: .whitespaces).lowercased()
        // The Mac's list arrives a moment after the session: wait for it briefly.
        for _ in 0..<30 where c.apps.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        guard let match = c.apps.first(where: { $0.name.lowercased() == wanted })
                ?? c.apps.first(where: { $0.name.lowercased().hasPrefix(wanted) })
                ?? c.apps.first(where: { $0.name.lowercased().contains(wanted) }) else { throw IntentError.noSuchApp }
        c.launch(bundleID: match.bundleID)
        return .result()
    }
}

struct PrivateModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Private Mode"
    static let description = IntentDescription("Blanks the Mac’s own screens while you work on it from here, or shows them again.")
    static let openAppWhenRun = true

    @Parameter(title: "On", default: true) var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = try await client()
        UserDefaults.standard.set(on ? StreamClient.PrivateMode.always.rawValue : StreamClient.PrivateMode.off.rawValue,
                                  forKey: StreamClient.privateModeKey)
        c.sendPrivacyIfNeeded()
        return .result()
    }
}

struct MacScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Screenshot of the Mac"
    static let description = IntentDescription("Saves what the Mac shows in RCL to Photos.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let c = try await client()
        try await connected(c)
        c.takeScreenshot()
        return .result()
    }
}

/// What Siri and Spotlight offer without setting anything up. Every phrase names the app.
struct RCLShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectToMacIntent(), phrases: [
            "Connect to my Mac with \(.applicationName)",
            "Conectar a mi Mac con \(.applicationName)",
            "Conecta mi Mac en \(.applicationName)",
        ], shortTitle: "Connect to Mac", systemImageName: "macbook")
        AppShortcut(intent: ShowMacDesktopIntent(), phrases: [
            "Show my Mac’s Desktop in \(.applicationName)",
            "Muestra el escritorio de mi Mac en \(.applicationName)",
        ], shortTitle: "Mac Desktop", systemImageName: "desktopcomputer")
        AppShortcut(intent: PrivateModeIntent(), phrases: [
            "Turn on Private Mode in \(.applicationName)",
            "Activa el modo privado en \(.applicationName)",
        ], shortTitle: "Private Mode", systemImageName: "eye.slash")
        AppShortcut(intent: MacScreenshotIntent(), phrases: [
            "Take a screenshot of my Mac with \(.applicationName)",
            "Captura la pantalla de mi Mac con \(.applicationName)",
        ], shortTitle: "Mac Screenshot", systemImageName: "camera.viewfinder")
    }
}
