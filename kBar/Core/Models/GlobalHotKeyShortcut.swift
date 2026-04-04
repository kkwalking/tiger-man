import AppKit
import Carbon
import Foundation

struct GlobalHotKeyShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifierFlagsRawValue: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlags
            .intersection(Self.supportedModifierFlags)
            .rawValue
    }

    static let defaultValue = GlobalHotKeyShortcut(
        keyCode: UInt16(kVK_ANSI_K),
        modifierFlags: [.control, .option, .command]
    )

    static let supportedModifierFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue).intersection(Self.supportedModifierFlags)
    }

    var displayName: String {
        Self.displayString(for: keyCode, modifiers: modifierFlags)
    }

    var isValid: Bool {
        !modifierFlags.isEmpty && !Self.modifierOnlyKeyCodes.contains(keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else {
            return false
        }

        return event.keyCode == keyCode &&
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(Self.supportedModifierFlags) == modifierFlags
    }

    static func fromRecordingEvent(_ event: NSEvent) -> GlobalHotKeyShortcut? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(supportedModifierFlags)

        guard !modifiers.isEmpty else {
            return nil
        }

        let shortcut = GlobalHotKeyShortcut(keyCode: event.keyCode, modifierFlags: modifiers)
        return shortcut.isValid ? shortcut : nil
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Function)
    ]

    private static func displayString(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        let modifierText = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : ""
        ].joined()

        return modifierText + keyDisplay(for: keyCode)
    }

    private static func keyDisplay(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_ForwardDelete: return "FnDelete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            return "Key\(keyCode)"
        }
    }
}

enum GlobalHotKeyShortcutStore {
    private static let defaultsKey = "kBar.globalHotKeyShortcut"

    static func load() -> GlobalHotKeyShortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(GlobalHotKeyShortcut.self, from: data),
              shortcut.isValid
        else {
            return .defaultValue
        }

        return shortcut
    }

    static func save(_ shortcut: GlobalHotKeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
