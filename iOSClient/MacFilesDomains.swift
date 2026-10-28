import FileProvider

/// The Files app's locations, one per paired Mac (the MacFiles extension), kept in step with the
/// saved list: a Mac paired gets one named after it, a Mac forgotten or removed loses it. Any thread.
enum MacFilesDomains {
    static func sync(_ macs: [SavedMac]) {
        let wanted = Dictionary(macs.filter { $0.revoked != true }.map { ($0.macID, $0.name) }, uniquingKeysWith: { a, _ in a })
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error { print("files: the Files app's locations couldn't be read (\(error.localizedDescription))"); return }
            var have: [String: String] = [:]
            for d in domains { have[d.identifier.rawValue] = d.displayName }
            for d in domains where wanted[d.identifier.rawValue] == nil {
                NSFileProviderManager.remove(d) { _ in }
            }
            for (id, name) in wanted where have[id] != name {
                NSFileProviderManager.add(NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: name)) { error in
                    print("files: \(name) " + (error.map { "not added to the Files app (\($0.localizedDescription))" } ?? "is in the Files app"))
                }
            }
        }
    }
}
