import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keep this Mac awake for RCL (Settings › General; on by default). A Mac asleep can't be found or
/// reached by a device, at home or away, and waking it from an iPad needs what iOS keeps from
/// apps (a broadcast, for Wake-on-LAN, needs an entitlement Apple grants by request) or a Bonjour
/// sleep proxy (an Apple TV or HomePod) that not every home has. So RCL keeps the Mac from idling
/// into sleep instead, only while it runs on its power adapter: on battery the Mac sleeps as
/// always. The display still sleeps (a device's arrival wakes it: DisplayWake), and closing the
/// lid, the Apple menu's Sleep or Energy settings still put it to sleep.
@MainActor
final class KeepAwake: ObservableObject {
    static let key = "keepAwake"

    @Published var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.key)
            apply()
        }
    }
    /// The Mac runs on its power adapter (or has no battery).
    @Published private(set) var onPower = true

    private var assertion: IOPMAssertionID = 0
    private var powerSource: CFRunLoopSource?

    init() {
        isOn = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        onPower = Self.readOnPower()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        apply()
    }

    /// What the pane says under the switch.
    var status: String {
        guard isOn else { return "This Mac sleeps on its usual schedule; while it sleeps, devices can’t reach it." }
        return onPower ? "This Mac stays awake while it’s on its power adapter, so devices can always reach it. Its display still sleeps, and wakes when a device connects."
                       : "On battery: this Mac sleeps on its usual schedule until it’s plugged in again."
    }

    private func powerChanged() {
        let now = Self.readOnPower()
        if now != onPower { onPower = now; apply() }
    }

    private func apply() {
        let want = isOn && onPower
        if want, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "RCL keeps this Mac reachable for your devices" as CFString, &assertion)
            print("Keep awake: on (power adapter); this Mac won't idle into sleep.")
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            print(isOn ? "Keep awake: on battery; this Mac sleeps as usual until plugged in." : "Keep awake: off.")
        }
    }

    private static func readOnPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
}
