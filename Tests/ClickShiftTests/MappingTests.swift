import Foundation
import Testing
@testable import ClickShift

@Suite struct DefaultBindings {
    @Test func myWhooshLayout() {
        #expect(ControllerButton.plus.defaultKey.name == "K")
        #expect(ControllerButton.minus.defaultKey.name == "I")
        #expect(ControllerButton.navUp.defaultKey.name == "↑")
        #expect(ControllerButton.navDown.defaultKey.name == "↓")
        #expect(ControllerButton.navLeft.defaultKey.name == "←")
        #expect(ControllerButton.navRight.defaultKey.name == "→")
    }

    @Test(arguments: ControllerButton.allCases)
    func everyButtonHasAKey(button: ControllerButton) {
        #expect(!button.defaultKey.isNone)
    }

    @Test func keyNamesAreUnique() {
        let names = KeyChoice.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func unknownKeyNameFallsBackToNone() {
        #expect(KeyChoice.named("no such key").isNone)
    }

    @Test func buttonsShownPerController() {
        #expect(ControllerButton.buttons(for: .clickV1) == [.plus, .minus])
        #expect(ControllerButton.buttons(for: .clickV2).count == 10)
    }
}

/// Uses an isolated UserDefaults suite, so it never touches the real app settings.
@Suite(.serialized) struct SavedBindings {
    let suiteName = "ClickShiftTests.\(UUID().uuidString)"

    func withIsolatedDefaults(_ body: () -> Void) {
        let original = MappingStore.defaults
        let isolated = UserDefaults(suiteName: suiteName)!
        MappingStore.defaults = isolated
        defer {
            MappingStore.defaults = original
            isolated.removePersistentDomain(forName: suiteName)
        }
        body()
    }

    @Test func savedKeyOverridesDefault() {
        withIsolatedDefaults {
            MappingStore.set(.named("Space"), for: .a)
            #expect(MappingStore.get(.a).name == "Space")
            #expect(MappingStore.get(.b) == ControllerButton.b.defaultKey)
        }
    }

    @Test func resetRestoresDefaults() {
        withIsolatedDefaults {
            MappingStore.set(.named("Space"), for: .plus)
            MappingStore.set(.none, for: .minus)
            MappingStore.reset()
            for button in ControllerButton.allCases {
                #expect(MappingStore.get(button) == button.defaultKey)
            }
        }
    }
}
