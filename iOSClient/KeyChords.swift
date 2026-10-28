import Foundation
import StreamProtocol

// The keys this device sends for a shortcut: the Spotlight key's ⌘Space, the portrait key row's keys
// with whatever is latched, a latched ⌘, ⌃ or ⌥ on the software keyboard, the modifiers the portrait
// trackpad holds down around a click or a drag, and a hardware keyboard's keys (Esc also through a
// key command, sent once whichever channel iPadOS uses). One place, so each
// goes out the way a keyboard sends it: a shortcut's modifiers pressed with their own keys around it,
// and every key's up after its down (2026-09-27, the stuck command after Spotlight). A shortcut sent
// as one key down and up carrying its modifiers left them set on every Mac from before that fix,
// which posted the up as it came, and the next click there was a ⌘-click.
//
// Pure: Foundation and StreamProtocol only, checked with swiftc beside the host's KeyStrokes
// (Tests/checks/key-strokes), which is what the Mac makes of these events.

/// The modifier bits an `InputEvent.key` carries: `UIKeyModifierFlags` raw values, which sit at the
/// same bit positions as the `CGEventFlags` the host posts with, so they travel unchanged.
struct KeyModifiers: OptionSet {
    let rawValue: UInt64

    static let shift   = KeyModifiers(rawValue: 1 << 17)
    static let control = KeyModifiers(rawValue: 1 << 18)
    static let option  = KeyModifiers(rawValue: 1 << 19)
    static let command = KeyModifiers(rawValue: 1 << 20)

    /// The three that make shortcuts instead of characters. Shift is not one of them: it changes
    /// which character the keyboard produces, which the text path already handles.
    static let shortcutMakers: KeyModifiers = [.control, .option, .command]

    /// Each latched modifier as its own key: the HID usage to press, and the bit it contributes.
    /// A pointer event has no modifier field, so a modified click has to hold these down around it.
    var keys: [(usage: UInt16, flag: KeyModifiers)] {
        var out: [(usage: UInt16, flag: KeyModifiers)] = []
        if contains(.control) { out.append((0xE0, .control)) }
        if contains(.shift)   { out.append((0xE1, .shift)) }
        if contains(.option)  { out.append((0xE2, .option)) }
        if contains(.command) { out.append((0xE3, .command)) }
        return out
    }

    /// The modifier a key is (a HID usage: left and right control, shift, option and command, 0xE0 to
    /// 0xE7), or nil for any other key.
    static func flag(forKey usage: UInt16) -> KeyModifiers? {
        switch usage {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .option
        case 0xE3, 0xE7: return .command
        default: return nil
        }
    }
}

enum KeyChord {
    /// One key with `modifiers`, as a keyboard sends it: each modifier's own key down, the key down
    /// and up carrying them all, each modifier's key up (`modifiersDown`, `modifiersUp`). With nothing
    /// latched, the key alone.
    static func press(_ usage: UInt16, with modifiers: KeyModifiers) -> [InputEvent] {
        modifiersDown(modifiers)
            + [.key(hidUsage: usage, down: true, modifiers: modifiers.rawValue),
               .key(hidUsage: usage, down: false, modifiers: modifiers.rawValue)]
            + modifiersUp(modifiers)
    }

    /// Spotlight on the Mac: exactly ⌘Space, ⌘'s own key down, Space down and up, ⌘ up.
    static let spotlight: [InputEvent] = press(0x2C, with: .command)

    /// Each of `modifiers`' own keys going down, in `KeyModifiers.keys`' order, each carrying the
    /// flags in force once it is down: what a shortcut and the trackpad's modified click or drag
    /// press first.
    static func modifiersDown(_ modifiers: KeyModifiers) -> [InputEvent] {
        var held: KeyModifiers = []
        return modifiers.keys.map { key in
            held.insert(key.flag)
            return .key(hidUsage: key.usage, down: true, modifiers: held.rawValue)
        }
    }

    /// The same keys going up in the reverse order, each carrying the flags still in force after it:
    /// what the shortcut and the click or the drag release after.
    static func modifiersUp(_ modifiers: KeyModifiers) -> [InputEvent] {
        var held = modifiers
        return modifiers.keys.reversed().map { key in
            held.remove(key.flag)
            return .key(hidUsage: key.usage, down: false, modifiers: held.rawValue)
        }
    }
}

/// A hardware keyboard's keys on their way to the Mac (InputOverlayView's pressesBegan, pressesEnded
/// and pressesCancelled, and its Esc key commands: `commanded`, `pressed`, `released`). A key goes to
/// the Mac as a key, or to the text system, when it goes down, and
/// its up follows the same way whatever the modifier flags say by then. Judged again at the release,
/// as before, a key held while ⌘ was let go went up in the text system and stayed down on the Mac, and
/// ⌘'s own release reached the Mac with command still on it, or not at all (UIKit's flags at a
/// modifier's release are those before or after it), so the Mac kept ⌘ held.
///
/// A key's down carries the flags UIKit gives it (the shortcut: ⌘⇧S with shift held for the text
/// system too); a modifier's own key and every up carry only the modifier keys down on the Mac, as a
/// keyboard would leave them, so a Mac from before 2026-09-27, which posts each key's flags as they
/// come, is left with nothing this device does not hold there.
struct ForwardedKeys {
    /// The keys whose down went to the Mac and whose up has not, in the order they went down.
    private(set) var down: [UInt16] = []
    /// When a key command last sent each key (`commanded`; systemUptime, as UIPress timestamps are),
    /// so the press of the same key that UIKit may hand pressesBegan after it is known for the same
    /// key press.
    private var commandedAt: [UInt16: Double] = [:]
    /// The keys whose press a key command had sent already (`pressed` swallowed it): their up is
    /// swallowed too, never handed to the text system.
    private(set) var swallowed: Set<UInt16> = []

    /// The keys the text system never delivers, which go to the Mac as keys whatever is held: the
    /// arrows, escape, forward delete, home, end, page up and down, F1 to F12, and ⌘, ⌃ and ⌥
    /// themselves (so a click while one is held is a modified click on the Mac).
    static let keyUsages: Set<UInt16> = [
        0x4F, 0x50, 0x51, 0x52,                                                   // right, left, down, up
        0x29, 0x4C, 0x4A, 0x4D, 0x4B, 0x4E,                                       // escape, forward delete, home, end, page up and down
        0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45,   // F1…F12
        0xE0, 0xE2, 0xE3, 0xE4, 0xE6, 0xE7,                                       // control, option, command, left and right
    ]

    /// Whether a key pressed with these modifiers goes to the Mac as a key rather than to the text
    /// system: one of `keyUsages`, or any key while ⌘, ⌃ or ⌥ is held, as those make shortcuts (⌘S,
    /// ⌃A, ⌥←) and never reach the text system. Shift alone makes characters, which the text system
    /// composes (shifted, dead-keyed, from an IME) and sends as text.
    static func goesAsKey(_ usage: UInt16, modifiers: UInt64) -> Bool {
        keyUsages.contains(usage) || modifiers & KeyModifiers.shortcutMakers.rawValue != 0
    }

    /// A key pressed, with the modifier flags UIKit gives it: its down, when it goes to the Mac as a
    /// key; nil when the text system takes it.
    mutating func began(_ usage: UInt16, modifiers: UInt64) -> [InputEvent] {
        guard Self.goesAsKey(usage, modifiers: modifiers) else { return [] }
        let switching = startsStandIn(usage, modifiers: modifiers)
        if !down.contains(usage) { down.append(usage) }
        let isModifier = KeyModifiers.flag(forKey: usage) != nil
        return switching + [.key(hidUsage: usage, down: true, modifiers: isModifier ? held : onMac(modifiers))]
    }

    /// A key released, or its press cancelled (the app going to the background, the keyboard gone):
    /// its up, when its down went to the Mac, with the modifier keys still down there; nil when the
    /// text system had it. The ⌥ that stands in for ⌘ (`standIn`) goes up as that ⌘.
    mutating func ended(_ usage: UInt16) -> InputEvent? {
        guard let i = down.firstIndex(of: usage) else { return nil }
        down.remove(at: i)
        if let s = standIn, s.option == usage {
            standIn = nil
            return .key(hidUsage: s.command, down: false, modifiers: held)
        }
        return .key(hidUsage: usage, down: false, modifiers: held)
    }

    // MARK: ⌥Tab and ⌥Space as the Mac's ⌘Tab and ⌘Space

    // iPadOS keeps ⌘Tab (its app switcher) and ⌘Space (its own Spotlight): no public API hands them to
    // an app, not even a key command asking for priority. So ⌥Tab opens the Mac's switcher and ⌥Space
    // its Spotlight: from that Tab or Space on, the ⌥ held down is a ⌘ on the Mac until it is let go,
    // as the Mac's switcher needs (more Tabs, ⇧Tab, Q or H, Esc, and the release that picks the app).
    // What it costs: a Mac leaves ⌥Tab unused, but ⌥Space types a non-breaking space there, which this
    // device can no longer send. Only while no ⌘ or ⌃ is down, so ⌃⌥Tab and ⌘⌥Space still go as they are.

    /// Tab and Space: the keys that turn the ⌥ held with them into ⌘.
    static let standInKeys: Set<UInt16> = [0x2B, 0x2C, 0x0B, 0x20, 0x21, 0x22]
    /// RCL: ⌥H (the Mac's ⌘H: iPadOS keeps ⌘H for Home) and ⌥⇧3, ⌥⇧4, ⌥⇧5 (the Mac's screenshots, not
    /// the iPad's). The digits only with ⇧: ⌥3 alone types a character on some layouts (# on a British
    /// one). Never a key whose ⌥ types something people use: ⌥ with the key left of 1 is \ on a
    /// Spanish layout, ⌥Q is @ on a Latin American one; those stay the Mac's ⌥ (⌘` goes as it is).
    static let standInNeedsShift: Set<UInt16> = [0x20, 0x21, 0x22]

    /// The ⌥ key held down that stands in for ⌘ (left or right), and the ⌘ key down on the Mac for it.
    private(set) var standIn: (option: UInt16, command: UInt16)?

    /// Tab or Space with ⌥ held, and no ⌘ or ⌃: the Mac's ⌥ goes up and its ⌘ down in its place,
    /// before the key.
    private mutating func startsStandIn(_ usage: UInt16, modifiers: UInt64) -> [InputEvent] {
        let others = KeyModifiers.command.rawValue | KeyModifiers.control.rawValue
        // Tab and Space go as keys only with ⌘, ⌃ or ⌥ held (`goesAsKey`), so with neither ⌘ nor ⌃ it is ⌥.
        guard Self.standInKeys.contains(usage), standIn == nil, modifiers & others == 0,
              !Self.standInNeedsShift.contains(usage) || modifiers & KeyModifiers.shift.rawValue != 0,
              let option = down.last(where: { $0 == 0xE2 || $0 == 0xE6 }) else { return [] }
        let command: UInt16 = option == 0xE6 ? 0xE7 : 0xE3
        let before = held
        standIn = (option, command)
        return [.key(hidUsage: option, down: false, modifiers: before & ~KeyModifiers.option.rawValue),
                .key(hidUsage: command, down: true, modifiers: held)]
    }

    /// UIKit's flags for a key as the Mac must see them: ⌥ as ⌘ while it stands in for it.
    private func onMac(_ modifiers: UInt64) -> UInt64 {
        guard standIn != nil else { return modifiers }
        return modifiers & ~KeyModifiers.option.rawValue | KeyModifiers.command.rawValue
    }

    /// Every key still down on the Mac going up, the last pressed first, each with the modifier keys
    /// still down after it: the overlay no longer taking keys (the Settings panel, the tour) or leaving
    /// the screen, after which UIKit sends it no release.
    mutating func releaseAll() -> [InputEvent] {
        var ups: [InputEvent] = []
        while let usage = down.last, let up = ended(usage) { ups.append(up) }
        swallowed.removeAll()
        return ups
    }

    // MARK: A key command's key (Esc)

    // iPadOS can keep a hardware Escape from pressesBegan (#67), so InputOverlayView also has key
    // commands for it, asking for priority over the text system. A key command has no up, so its key
    // goes down and up at once. A device that hands the same press to both must not send it twice:
    // the press came first (its down is in `down`), and the command sends nothing; or the command came
    // first, and the press, no later than the command, is swallowed with its up.

    /// What pressesBegan, pressesEnded and pressesCancelled do with a hardware key.
    enum Press: Equatable {
        /// To the Mac (more than one when ⌥Tab or ⌥Space turns ⌥ into ⌘ first).
        case send([InputEvent])
        /// To the text system (super), which types it.
        case text
        /// Nowhere: a key command sent this press already.
        case swallow
    }

    /// A key command for `usage`, fired at `time` (systemUptime) with its modifiers: the key's down and
    /// up as `began` and `ended` make them. Nothing when the key is down on the Mac already: its press
    /// came first, and that press's own up follows.
    mutating func commanded(_ usage: UInt16, modifiers: UInt64, at time: Double) -> [InputEvent] {
        guard !down.contains(usage) else { return [] }
        let press = began(usage, modifiers: modifiers)
        guard !press.isEmpty else { return [] }
        commandedAt[usage] = time
        return press + (ended(usage).map { [$0] } ?? [])
    }

    /// A key pressed (pressesBegan), with UIKit's modifier flags and its press's timestamp: `began`'s
    /// answer, unless a key command sent the same key press already (the same key, pressed no later than
    /// the command fired), which is swallowed, and its up with it.
    mutating func pressed(_ usage: UInt16, modifiers: UInt64, at time: Double) -> Press {
        if let sent = commandedAt[usage], time <= sent {
            swallowed.insert(usage)
            return .swallow
        }
        let events = began(usage, modifiers: modifiers)
        return events.isEmpty ? .text : .send(events)
    }

    /// A key released or its press cancelled (pressesEnded, pressesCancelled): `ended`'s answer, or
    /// swallowed when its press was.
    mutating func released(_ usage: UInt16) -> Press {
        if swallowed.remove(usage) != nil { return .swallow }
        return ended(usage).map { .send([$0]) } ?? .text
    }

    /// The modifier flags of the modifier keys down on the Mac (the ⌥ standing in for ⌘ as ⌘).
    private var held: UInt64 {
        down.reduce(0) { flags, usage in
            let onMac = standIn?.option == usage ? standIn!.command : usage
            return flags | (KeyModifiers.flag(forKey: onMac)?.rawValue ?? 0)
        }
    }
}
