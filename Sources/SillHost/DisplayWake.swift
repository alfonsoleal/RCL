import Foundation
import IOKit.pwr_mgt

/// The Mac's display while devices watch it (#134). Asleep, ScreenCaptureKit hands over black
/// frames, so a device that connects to a Mac whose display slept saw only black until someone woke
/// it there. So a device's arrival counts as someone at the Mac (it wakes the display, as a key
/// press would), and while any device is connected the display does not idle to sleep: watching a
/// video from bed sends no input, and the picture must not go black under it. The Mac's own sleep
/// (the lid, the Apple menu) is left alone, and so is the lock screen: a locked Mac shows its lock
/// screen on the device.
@MainActor
final class DisplayWake {
    private var held: IOPMAssertionID = 0
    /// A synthetic host streams a test pattern and must not keep this Mac's display on.
    private let enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    /// A device connected: the display wakes now.
    func deviceArrived() {
        guard enabled else { return }
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("RCL: a device connected" as CFString, kIOPMUserActiveLocal, &activity)
    }

    /// How many devices are connected: from one up, the display is held awake; at none, let go.
    func devices(_ count: Int) {
        guard enabled else { return }
        if count > 0, held == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "RCL: a device is watching this Mac" as CFString, &held)
        } else if count == 0, held != 0 {
            IOPMAssertionRelease(held)
            held = 0
        }
    }
}
