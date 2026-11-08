import ApplicationServices
import AppKit
import Carbon.HIToolbox

/// A key the user can assign to an action.
struct KeyChoice: Hashable, Identifiable {
    let name: String
    let code: CGKeyCode
    var id: CGKeyCode { code }

    static let all: [KeyChoice] = {
        let letters: [(String, Int)] = [
            ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E),
            ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J),
            ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O),
            ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
            ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y),
            ("Z", kVK_ANSI_Z),
            ("←", kVK_LeftArrow), ("→", kVK_RightArrow), ("↑", kVK_UpArrow), ("↓", kVK_DownArrow),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
            ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab), ("Esc", kVK_Escape),
            ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            ("Page Up", kVK_PageUp), ("Page Down", kVK_PageDown),
        ]
        return [none] + letters.map { KeyChoice(name: $0.0, code: CGKeyCode($0.1)) }
    }()

    static let none = KeyChoice(name: "—", code: CGKeyCode.max)
    var isNone: Bool { self == .none }

    static func named(_ n: String) -> KeyChoice { all.first { $0.name == n } ?? .none }
}

/// Posts synthetic key events. Requires Accessibility permission.
enum KeyEmitter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    /// `autorepeat` marks repeated key-downs the way a held physical key does.
    static func post(_ code: CGKeyCode, down: Bool, autorepeat: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }
}
