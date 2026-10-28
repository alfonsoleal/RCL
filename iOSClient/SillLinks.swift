import Foundation

/// Where RCL sends people outside the app: its App Store page, the link under a Mac's update notice.
/// Sill's own site (getsill.app) and its App Store record are Noah's, so none of them is RCL's.
enum SillLinks {
    /// RCL's App Store page, https://apps.apple.com/app/id‹Apple ID›, once it has one. While the
    /// placeholder stays, no link shows (the update notice's own words say what to do), and
    /// release-ios.sh only warns.
    static let appStoreText = "APP_STORE_URL_PLACEHOLDER"

    /// An https URL from `appStoreText`, else nil. DEBUG: `-SillAppStoreURL <url>` replaces it.
    static var appStore: URL? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "SillAppStoreURL"), let url = https(override) { return url }
        #endif
        return https(appStoreText)
    }

    private static func https(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
