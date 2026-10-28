import SwiftUI
import StreamProtocol

/// Type on This iPhone (RCL's compact controls): a native text field, with autocorrection, the
/// keyboard's dictation and editing, whose text goes to the Mac in one go where its focus is, as if
/// typed there. Easier on a phone than typing key by key against the Mac. Stays open for the next
/// piece; Return sends one Return on its own (to send a message, run a search).
struct ComposeSheet: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    /// What went last, for the line under the field.
    @State private var sent: String?
    @State private var editingShortcuts = false

    private var mac: String { client.macName.isEmpty ? String(localized: "the Mac") : client.macName }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Type or dictate…", text: $text, axis: .vertical)
                    .font(.geist(.body))
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.control))
                HStack(spacing: 10) {
                    Button { send(text, thenReturn: false) } label: {
                        Label("Send", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
                    Button { send(text, thenReturn: true) } label: {
                        Text("Send + ⏎").lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(text.isEmpty)
                    .accessibilityLabel("Send, then Return")
                    Button { send("", thenReturn: true) } label: { Image(systemName: "return") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Return on \(mac)")
                }
                .font(.geist(.subheadline, .semibold))
                Text(sent.map { String(localized: "Sent to \(mac): \($0)") } ?? String(localized: "Goes where \(mac)’s cursor is, as if typed there."))
                    .font(.geist(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The person's Mac shortcuts (MacShortcuts), a tap each.
                ScrollView {
                    ShortcutGrid(client: client, columns: 3) { editingShortcuts = true }
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Type on \(mac)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Palette.accent)
        .presentationDetents([.height(260), .medium, .large])
        .sheet(isPresented: $editingShortcuts) { ShortcutEditor() }
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func send(_ string: String, thenReturn: Bool) {
        let all = string + (thenReturn ? "\n" : "")
        guard !all.isEmpty else { return }
        client.sendInput(.text(all))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sent = string.isEmpty ? String(localized: "Return") : string
        text = ""
    }
}
