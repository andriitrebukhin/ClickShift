import Foundation

extension ControllerButton {
    /// Defaults match MyWhoosh's keyboard controls: + = K (shift up), − = I (shift down),
    /// D-pad = arrow keys. A/B/Y/Z send their own letter.
    var defaultKey: KeyChoice {
        switch self {
        case .plus: .named("K")
        case .minus: .named("I")
        case .navLeft: .named("←")
        case .navRight: .named("→")
        case .navUp: .named("↑")
        case .navDown: .named("↓")
        case .a: .named("A")
        case .b: .named("B")
        case .y: .named("Y")
        case .z: .named("Z")
        }
    }
}

enum MappingStore {
    /// Where bindings are saved. Tests swap in an isolated suite.
    static var defaults = UserDefaults.standard

    private static func storageKey(_ b: ControllerButton) -> String { "btn.\(b.rawValue).key" }

    static func get(_ b: ControllerButton) -> KeyChoice {
        defaults.string(forKey: storageKey(b)).map(KeyChoice.named) ?? b.defaultKey
    }

    static func set(_ k: KeyChoice, for b: ControllerButton) {
        defaults.set(k.name, forKey: storageKey(b))
    }

    static func reset() {
        ControllerButton.allCases.forEach { defaults.removeObject(forKey: storageKey($0)) }
    }
}
