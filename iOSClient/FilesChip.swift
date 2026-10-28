import SwiftUI
import UIKit
import StreamProtocol

/// The files chip over the stream (StreamClient+Files): one row per file going to the Mac or coming
/// from it, with its share; a file that came is opened in the Files app (where RCL's folder holds it)
/// or shared on, and dismissed by hand. StreamScreen places it in the stream panel's top-leading
/// corner, away from the clipboard's.
struct FilesChip: View {
    @ObservedObject var client: StreamClient

    private var mac: String { client.macName.isEmpty ? String(localized: "the Mac") : client.macName }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(client.fileTransfers) { t in
                row(t).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(.easeOut(duration: 0.2), value: client.fileTransfers)
    }

    private func row(_ t: FileTransfer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(t))
                .font(.geist(.footnote, .semibold))
                .foregroundStyle(tint(t))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name)
                    .font(.geist(.footnote, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .moving = t.state {
                    ProgressView(value: t.fraction)
                        .tint(Palette.accent)
                        .frame(width: 140)
                } else {
                    Text(caption(t))
                        .font(.geist(.caption))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(t.name), \(caption(t))")
            if case .finished(let url?) = t.state {
                Button("Open") { open(url) }
                    .font(.geist(.footnote, .semibold))
                    .foregroundStyle(Palette.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.geist(.footnote, .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Share \(t.name)")
            }
            Button(action: { client.dismissFile(t.id) }) {
                Image(systemName: "xmark")
                    .font(.geist(.footnote, .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.isOver ? String(localized: "Dismiss") : String(localized: "Stop sending \(t.name)"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .rclGlass(in: Capsule(style: .continuous), tint: 0.7)
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ t: FileTransfer) -> String {
        switch t.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .finished: return "checkmark.circle.fill"
        default: return t.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private func tint(_ t: FileTransfer) -> Color {
        if case .failed = t.state { return .orange }
        if case .finished = t.state { return Palette.accent }
        return Palette.muted
    }

    private func caption(_ t: FileTransfer) -> String {
        switch t.state {
        case .waiting: return String(localized: "Waiting to go to \(mac)")
        case .moving: return String(localized: "\(Int((t.fraction * 100).rounded())) % of \(FileShare.size(t.size))")
        case .finished: return t.direction == .incoming ? String(localized: "From \(mac) · in Files › RCL") : String(localized: "Sent to \(mac)’s Downloads")
        case .failed(let why): return why
        }
    }

    /// The Files app, at the file: its own URL scheme for a file in an app's shared folder.
    private func open(_ url: URL) {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "shareddocuments"
        if let shared = parts?.url { UIApplication.shared.open(shared) }
    }
}
