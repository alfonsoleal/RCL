# RCL

Your Mac's windows on your iPad and iPhone, streamed live and controlled with touch, a trackpad,
a keyboard or Apple Pencil.

RCL is a derivative of [Sill](https://github.com/Saffsanity/sill) by Noah Saffer, under the Apache
License 2.0. It is not affiliated with Sill or endorsed by its author; see [NOTICE](NOTICE).

| What it does | What it doesn't |
|---|---|
| Streams one Mac window, or the whole desktop, to an iPad or iPhone as HEVC video, with your taps, clicks, scrolls and keys going back | Need an account or a server: your devices talk to your Mac directly |
| Connects on the same network, over a USB cable, peer to peer, or from away through your own VPN (Tailscale) with Remote Access | Work without the RCL app running on the Mac |
| Pairs each device once (a QR code or a 12-digit code), TLS 1.3 with both keys pinned | Share anything with anyone but the devices you pair |
| Adapts to the link: live bitrate, recovery without keyframes, sharp text at rest, QUIC away from home | Stream audio from the device to the Mac (the Mac's sound does play on the device) |
| Files both ways, the Mac in the Files app, the clipboard, screenshots, Private Mode, Handoff, Siri and widgets | Run on Intel Macs or before macOS 14 / iOS 17 |

## What RCL adds to Sill

- **The Floating Pill**: the picture fills the screen and a Liquid Glass pill floats in a corner (or
  sits as a notch); it widens into the whole bar, with the open windows' icons and a vertical
  windows menu.
- **The adaptive encoder**: VideoToolbox's low-latency rate control with long-term references. A lost
  frame recovers from an acknowledged reference instead of a keyframe, and the bitrate follows the
  link live; one boosted keyframe sharpens a still picture after motion.
- **QUIC away from home**, with a side connection for pings, ticks and the pointer, and a notice when
  Tailscale relays the connection instead of going directly.
- **Files**: send and get files, drop files onto the picture (the Mac drags them into the app under
  the point), the Mac as a location in the Files app.
- **Private Mode** (the Mac's own screens go black), the quick password (Face ID types the Mac's
  password on its lock screen), Handoff between iPhone and iPad, Siri and Shortcuts, widgets and a
  Control Center control.
- **Match the Screen** and **Wide Color (P3, 10-bit)**, both optional.
- The iOS app in English and Spanish, with its own language picker.

## Requirements

- A Mac with Apple silicon on macOS 14 or later, running the RCL menu bar app.
- An iPhone or iPad on iOS / iPadOS 17 or later (some features need iOS 18 or 26).
- Xcode 27.1 or later to build.

## Building

The Mac host is a Swift package; the iOS app is the Xcode project in `iOSClient/`.

```bash
swift build -c release
```

```bash
Scripts/make-app.sh --install --open
```

Then open `iOSClient/Sill.xcodeproj`, choose your team, and run the `Sill` scheme on your device.
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the details, the test hosts and the checks
(`Tests/checks/run-all.sh`).

The code keeps Sill's internal names (`SillHost`, `Sill.xcodeproj`, the `sill/1` protocol) so it can
still follow Sill's changes; what a person sees says RCL. `docs/` and `CLAUDE.md` are Sill's
development notes, kept for their history and context.

## Security

Please report a vulnerability privately; [SECURITY.md](SECURITY.md) says how.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Noah Saffer for Sill; RCL's changes copyright 2026
Alfonso Leal Davison, under the same license.
