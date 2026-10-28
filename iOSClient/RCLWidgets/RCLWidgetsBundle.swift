import WidgetKit
import SwiftUI

/// RCL's widgets: the last Mac on the Home Screen and the Lock Screen, the paired Macs with the
/// Desktop and Private Mode, and Connect to Mac in Control Center. Each is a link into RCL
/// (`rcl://connect`, `rcl://desktop`, `rcl://private`): the session is the app's.
@main
struct RCLWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MacWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            ConnectControl()
        }
    }
}
