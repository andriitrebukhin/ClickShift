import SwiftUI

@main
struct ClickShiftApp: App {
    @StateObject private var manager = ControllerManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            Image(systemName: manager.controllers.contains { $0.state == .ready } ? "bicycle.circle.fill" : "bicycle.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var manager: ControllerManager

    private var shownKind: ControllerKind { manager.controllers.first?.kind ?? manager.lastKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ClickShift").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $manager.enabled).toggleStyle(.switch).controlSize(.small)
            }

            if !manager.accessibilityGranted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility permission is needed to send key presses to other apps.")
                            .font(.callout)
                        HStack {
                            Button("Grant…") { KeyEmitter.requestTrust() }
                            Button("Open Settings") { KeyEmitter.openAccessibilitySettings() }
                            Button("Re-check") { manager.accessibilityGranted = KeyEmitter.isTrusted }
                        }
                    }
                }
            }

            GroupBox("Controllers") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.bluetoothStatus).font(.caption).foregroundStyle(.secondary)
                    if manager.controllers.isEmpty {
                        Text(manager.isScanning ? "Searching… wake the Click by pressing a button." : "No controller connected.")
                            .font(.callout)
                    }
                    ForEach(manager.controllers) { c in
                        HStack {
                            Image(systemName: c.state == .ready ? "checkmark.circle.fill" : "ellipsis.circle")
                                .foregroundStyle(c.state == .ready ? .green : .secondary)
                            Text(c.kind.rawValue)
                            if c.state != .ready { Text(c.state.rawValue).foregroundStyle(.secondary) }
                            Spacer()
                            if let b = c.battery { Text("\(b)%").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                    HStack {
                        Button(manager.isScanning ? "Stop scan" : "Scan") {
                            manager.isScanning ? manager.stopScan() : manager.startScan()
                        }
                        Button("Disconnect all") { manager.disconnectAll() }
                            .disabled(manager.controllers.isEmpty)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ButtonSection.sections(for: shownKind)) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                                      alignment: .leading, spacing: 4) {
                                ForEach(section.buttons) { ButtonCell(manager: manager, button: $0) }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Reset to defaults") { manager.resetMappings() }.controlSize(.small)
                    }
                }
            } label: {
                Text("Buttons – \(shownKind.rawValue)")
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manager.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            }

            HStack {
                Text("Key presses go to the app in focus.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { manager.accessibilityGranted = KeyEmitter.isTrusted }
    }
}

struct ButtonSection: Identifiable {
    let title: String
    let buttons: [ControllerButton]
    var id: String { title }

    static func sections(for kind: ControllerKind) -> [ButtonSection] {
        let shift = ButtonSection(title: "Shift", buttons: [.plus, .minus])
        guard kind == .clickV2 else { return [shift] }
        return [
            shift,
            ButtonSection(title: "D-pad", buttons: [.navUp, .navDown, .navLeft, .navRight]),
            ButtonSection(title: "Buttons", buttons: [.a, .b, .y, .z]),
        ]
    }
}

/// Compact "label  [key ▾]" cell; highlighted while the physical button is held.
struct ButtonCell: View {
    @ObservedObject var manager: ControllerManager
    let button: ControllerButton

    var body: some View {
        let isPressed = manager.pressedButtons.contains(button)
        HStack(spacing: 6) {
            Text(button.shortTitle)
                .fontWeight(isPressed ? .bold : .regular)
                .foregroundStyle(isPressed ? Color.accentColor : .primary)
                .frame(width: 40, alignment: .leading)
            Picker("", selection: Binding(
                get: { manager.key(for: button) },
                set: { manager.setKey($0, for: button) }
            )) {
                ForEach(KeyChoice.all) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(isPressed ? Color.accentColor.opacity(0.15) : .clear))
    }
}
