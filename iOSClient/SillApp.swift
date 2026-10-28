import SwiftUI

@main
struct SillApp: App {
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (SillAppDelegate).
    @UIApplicationDelegateAdaptor(SillAppDelegate.self) var appDelegate

    init() {
        // On an iPhone held sideways the bar hides by default (RCL): every point goes to the picture,
        // and a swipe down brings the bar back. An iPad keeps it, as it has the room.
        // The magnifier: on an iPhone the picture is small, so on and filling its pane; on an iPad the
        // picture fills its panel already, so off, and twice as large when it is turned on.
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        UserDefaults.standard.register(defaults: [StreamClient.hideBarKey: phone,
                                                  StreamClient.magnifierKey: phone,
                                                  StreamClient.autoQualityKey: true,
                                                  StreamClient.magnifierLevelKey: phone ? 0.0 : 2.0])
    }

    var body: some Scene {
        WindowGroup {
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            ContentView()
                // Geist for every Text that names no font of its own (Typography.swift).
                .font(.geist(.body))
                .readsDuoPosture()
        }
    }
}
