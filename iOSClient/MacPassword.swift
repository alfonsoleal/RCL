import Foundation
import LocalAuthentication
import Security

/// Quick password (RCL): a Mac's login password kept on this device, to type on the Mac's lock
/// screen after Face ID (or the device's passcode). In the Keychain, this device only, behind
/// `.userPresence`: nothing reads it without the person's face or passcode, not even RCL. One per
/// Mac, by its Mac ID (or its name, for a Mac reached by address). Never sent anywhere but typed on
/// that Mac, as keys.
enum MacPassword {
    private static let service = "me.alfonso.rcl.mac-password"

    static func has(for mac: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true    // ask whether it's there, never prompt for it
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    @discardableResult
    static func save(_ password: String, for mac: String) -> Bool {
        forget(for: mac)
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
        else { return false }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: mac,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget(for mac: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: mac]
        SecItemDelete(query as CFDictionary)
    }

    /// The password, after Face ID or the passcode; nil when the person cancels or it isn't saved.
    static func read(for mac: String, reason: String) async -> String? {
        await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: mac,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationContext as String: context,
                ]
                var out: CFTypeRef?
                let ok = SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
                k.resume(returning: ok ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil)
            }
        }
    }
}

import SwiftUI

/// Typing a Mac's password once, to keep it (MacPassword).
struct MacPasswordSheet: View {
    let mac: String
    let key: String
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("The password you type on \(mac)’s lock screen. It stays on this device, in the Keychain, and RCL types it for you after Face ID.")
                }
            }
            .navigationTitle("\(mac)’s Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(password.isEmpty) }
            }
        }
        .tint(Palette.accent)
        .onAppear { focused = true }
    }

    private func save() {
        guard !password.isEmpty, MacPassword.save(password, for: key) else { return }
        password = ""
        saved()
        dismiss()
    }
}

/// Over the stream while the Mac is locked: unlock with Face ID, or save the password first.
struct MacLockedCard: View {
    @ObservedObject var client: StreamClient
    @State private var saving = false
    @State private var hasPassword = false

    private var mac: String { client.macName.isEmpty ? String(localized: "The Mac") : client.macName }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.geist(18)).foregroundStyle(Palette.text)
            Text("\(mac) is locked").font(.geist(.subheadline, .medium)).foregroundStyle(Palette.text).lineLimit(1)
            Button {
                if hasPassword { client.unlockMac() } else { saving = true }
            } label: {
                Label(hasPassword ? String(localized: "Unlock") : String(localized: "Save Password…"), systemImage: hasPassword ? "faceid" : "key")
                    .font(.geist(.subheadline, .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .rclGlass(in: Capsule(), tint: 0.7)
        .tint(Palette.accent)
        .onAppear { hasPassword = client.hasMacPassword }
        .sheet(isPresented: $saving) {
            if let key = client.passwordKey {
                MacPasswordSheet(mac: mac, key: key) { hasPassword = true; client.unlockMac() }
            }
        }
    }
}
