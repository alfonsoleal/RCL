import UniformTypeIdentifiers
import SwiftUI
import StreamProtocol

/// The clipboard's chip over the stream (docs/clipboard-plan.md): "Paste on ‹Mac›", then press ⌘V
/// there, with the system's Paste button and Dismiss; for a moment after a Paste, its note in the same
/// place. Offered by StreamClient (`clipboardChip`, ClipboardPolicy.offersChip); placed and hidden by
/// StreamScreen. Takes no touch outside itself.
struct ClipboardChip: View {
    @ObservedObject var client: StreamClient

    private var mac: String { client.macName.isEmpty ? String(localized: "the Mac") : client.macName }

    var body: some View {
        ZStack(alignment: .trailing) {
            if let note = client.clipboardNote {
                noteView(note)
                    .transition(.opacity)
            } else if client.clipboardChip {
                chip
                    .transition(.opacity)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(.easeOut(duration: 0.2), value: client.clipboardChip)
        .animation(.easeOut(duration: 0.2), value: client.clipboardNote)
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.geist(.footnote, .semibold))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(ClipboardPolicy.Copy.chipTitle(mac: mac))
                    .font(.geist(.footnote, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ClipboardPolicy.Copy.chipSubtitle)
                    .font(.geist(.caption))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            // One element for the words; the Paste button and Dismiss are their own.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ClipboardPolicy.Copy.chipSpoken(mac: mac, device: StreamClient.deviceWord))
            .accessibilityAddTraits(.isStaticText)
            ClipboardPasteButton(client: client)
            Button(action: { client.dismissClipboardChip() }) {
                Image(systemName: "xmark")
                    .font(.geist(.footnote, .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ClipboardPolicy.Copy.dismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .rclGlass(in: Capsule(style: .continuous), tint: 0.7)
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private func noteView(_ note: ClipboardNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(note.warning ? Color.orange : Palette.accent)
                .accessibilityHidden(true)
            Text(note.text)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.geist(.footnote))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .rclGlass(in: Capsule(style: .continuous), tint: 0.7)
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.spoken)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The system's Paste button (SwiftUI's PasteButton, UIPasteControl): the person's tap reads this
/// device's clipboard without iOS asking, and what it read goes to the Mac (`sendClipboard`). Disabled
/// by the system while the clipboard has no text. Its label is the system's ("Paste").
struct ClipboardPasteButton: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        // Text, or since RCL's clipboard 2 an image: text first, as the Mac does.
        PasteButton(supportedContentTypes: ClipboardImage.pasteTypes(images: ClipboardPolicy.hostTakesImages(client.hostClipboard))) { providers in
            ClipboardImage.load(providers) { text, image in
                // On the main thread whatever queue the system hands it on.
                DispatchQueue.main.async {
                    if let text { client.sendClipboard([text]) } else if let image { client.sendClipboardImage(image) }
                }
            }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .tint(Palette.accent)
        .accessibilityHint(ClipboardPolicy.Copy.pasteHint(mac: client.macName.isEmpty ? String(localized: "the Mac") : client.macName,
                                                          device: StreamClient.deviceWord))
    }
}

/// What the Paste control reads on this device, and an image made ready for the Mac (RCL's clipboard
/// 2): PNG as copied (a screenshot, a design app's selection); a photo (HEIC, JPEG) as a JPEG at 0.9;
/// over `Clipboard.maxImageBytes`, fewer pixels until it fits (else it goes as it is and the policy
/// says it is too large).
enum ClipboardImage {
    static func pasteTypes(images: Bool) -> [UTType] {
        images ? [.plainText, .png, .image] : [.plainText]
    }

    static func load(_ providers: [NSItemProvider], done: @escaping (String?, Data?) -> Void) {
        guard let provider = providers.first else { done(nil, nil); return }
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in done(text, nil) }
            return
        }
        let png = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
        let type = png ? UTType.png : UTType.image
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            done(nil, data.flatMap { ready($0, isPNG: png) })
        }
    }

    static func ready(_ data: Data, isPNG: Bool) -> Data? {
        let cap = Clipboard.maxImageBytes
        if isPNG, data.count <= cap { return data }
        guard let image = UIImage(data: data) else { return nil }
        for scale in [1.0, 0.75, 0.5, 1.0 / 3] {
            let picture = scale == 1 ? image : resized(image, scale)
            if let jpeg = picture.jpegData(compressionQuality: 0.9), jpeg.count <= cap { return jpeg }
        }
        return image.jpegData(compressionQuality: 0.7)
    }

    private static func resized(_ image: UIImage, _ scale: Double) -> UIImage {
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
