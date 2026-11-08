import CoreBluetooth
import Foundation

/// One known Zwift controller. Kept across disconnects so we can reconnect to the same peripheral.
final class Controller: Identifiable {
    enum State: String { case connecting = "Connecting…", ready = "Ready", reconnecting = "Reconnecting…" }

    let peripheral: CBPeripheral
    let kind: ControllerKind
    var id: UUID { peripheral.identifier }
    var state = State.connecting
    var syncRx: CBCharacteristic?
    var battery: Int?
    var pressed = Set<ControllerButton>()
    var unknownBits: UInt64 = 0
    var pressedAt: [ControllerButton: Date] = [:]
    var repeatTimer: Timer?
    var disconnects = 0
    var connectedAt: Date?
    var loggedVendorMessage = false

    init(peripheral: CBPeripheral, kind: ControllerKind) {
        self.peripheral = peripheral
        self.kind = kind
    }
}

final class ControllerManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothStatus = "Starting…"
    @Published private(set) var isScanning = false
    @Published private(set) var controllers: [Controller] = []
    @Published private(set) var log: [String] = []
    @Published var accessibilityGranted = KeyEmitter.isTrusted

    @Published var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    /// Buttons currently held on any controller (used to highlight rows in the UI).
    @Published private(set) var pressedButtons = Set<ControllerButton>()
    /// Last controller kind seen, so the mapping UI shows the right buttons while disconnected.
    @Published private(set) var lastKind = ControllerKind(rawValue: UserDefaults.standard.string(forKey: "lastKind") ?? "") ?? .clickV1

    /// Like a keyboard: after this delay a held button repeats its key at this interval.
    private let repeatDelay: TimeInterval = 0.35
    /// Shortest key press we emit; games that poll keyboard state can miss shorter ones.
    private let minPress: TimeInterval = 0.04

    private var central: CBCentralManager!
    private var known: [UUID: Controller] = [:]
    private let logFile = FileLog()

    override init() {
        super.init()
        // First regular log line (the file already carries it as its own header).
        log = ["\(Date().formatted(date: .omitted, time: .standard))  \(FileLog.header)"]
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Mapping

    func key(for b: ControllerButton) -> KeyChoice { MappingStore.get(b) }

    func setKey(_ k: KeyChoice, for b: ControllerButton) {
        objectWillChange.send()
        MappingStore.set(k, for: b)
    }

    func resetMappings() {
        objectWillChange.send()
        MappingStore.reset()
    }

    // MARK: Scanning / connection

    func startScan() {
        guard central.state == .poweredOn, !isScanning else { return }
        // No service filter: controllers are identified by Zwift manufacturer data.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        append("Scanning for Zwift Click…")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    /// Disconnects and forgets all controllers. Press Scan to find them again.
    func disconnectAll() {
        let all = Array(known.values)
        known.removeAll()
        for c in all {
            releaseAll(c)
            central.cancelPeripheralConnection(c.peripheral)
        }
        stopScan()
        refresh()
        append("Disconnected all controllers")
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(ts)  \(line)", at: 0)
        if log.count > FileLog.maxLines { log.removeLast(log.count - FileLog.maxLines) }
        logFile.write(line)
    }

    private func refresh() { controllers = known.values.sorted { $0.kind.rawValue < $1.kind.rawValue } }

    // MARK: Button handling — buttons behave like keyboard keys

    private func handle(_ buttons: Set<ControllerButton>, unknownBits: UInt64, on c: Controller) {
        // Logged only when they change, so repeated messages can't flood the 100-line log.
        if unknownBits != c.unknownBits {
            c.unknownBits = unknownBits
            if unknownBits != 0 { append(String(format: "Unknown button bits pressed: 0x%04llX", unknownBits)) }
        }
        guard buttons != c.pressed else { return } // device re-sends identical states

        let released = c.pressed.subtracting(buttons)
        let newlyPressed = buttons.subtracting(c.pressed)
        c.pressed = buttons
        pressedButtons = Set(known.values.flatMap(\.pressed))
        append(buttons.isEmpty ? "released" : buttons.map(\.title).sorted().joined(separator: " + "))

        accessibilityGranted = KeyEmitter.isTrusted
        guard enabled else { return }

        for b in released { keyUp(b, on: c) }
        for b in newlyPressed {
            let k = key(for: b)
            guard !k.isNone else { continue }
            c.pressedAt[b] = Date()
            KeyEmitter.post(k.code, down: true)
        }

        c.repeatTimer?.invalidate()
        c.repeatTimer = nil
        guard buttons.contains(where: { !key(for: $0).isNone }) else { return }
        c.repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: true) { [weak self, weak c] _ in
            guard let self, let c, self.enabled else { return }
            for b in c.pressed where !self.key(for: b).isNone {
                KeyEmitter.post(self.key(for: b).code, down: true, autorepeat: true)
            }
        }
    }

    private func keyUp(_ b: ControllerButton, on c: Controller) {
        guard let pressedAt = c.pressedAt.removeValue(forKey: b) else { return }
        let code = key(for: b).code
        let wait = minPress - Date().timeIntervalSince(pressedAt)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { KeyEmitter.post(code, down: false) }
        } else {
            KeyEmitter.post(code, down: false)
        }
    }

    private func releaseAll(_ c: Controller) {
        c.repeatTimer?.invalidate()
        c.repeatTimer = nil
        for b in c.pressed { keyUp(b, on: c) }
        c.pressed = []
        pressedButtons = Set(known.values.flatMap(\.pressed))
    }

    private func write(_ bytes: [UInt8], to c: Controller) {
        guard let ch = c.syncRx else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        c.peripheral.writeValue(Data(bytes), for: ch, type: type)
    }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

// MARK: - CBCentralManagerDelegate

extension ControllerManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth on"
            // Re-issue pending connections (e.g. after Bluetooth was toggled), else scan.
            known.values.forEach { central.connect($0.peripheral) }
            if known.isEmpty { startScan() }
        case .poweredOff: bluetoothStatus = "Bluetooth is off"; isScanning = false
        case .unauthorized: bluetoothStatus = "Bluetooth permission denied (System Settings › Privacy › Bluetooth)"
        case .unsupported: bluetoothStatus = "Bluetooth LE not supported"
        default: bluetoothStatus = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard known[peripheral.identifier] == nil,
              let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let kind = ControllerKind.from(manufacturerData: mfg) else { return }

        let c = Controller(peripheral: peripheral, kind: kind)
        lastKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "lastKind")
        known[peripheral.identifier] = c
        peripheral.delegate = self
        append("Found \(kind.rawValue) (RSSI \(RSSI)) – connecting")
        stopScan()
        central.connect(peripheral)
        refresh()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let c = known[peripheral.identifier] else { return }
        c.connectedAt = Date()
        append("Connected to \(c.kind.rawValue)")
        peripheral.discoverServices([c.kind.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let c = known[peripheral.identifier] else { return }
        append("Connect failed: \(error?.localizedDescription ?? "unknown") – retrying")
        c.state = .reconnecting
        refresh()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let c = known[peripheral.identifier] else { return } // forgotten via Disconnect all
        releaseAll(c)
        c.disconnects += 1
        c.state = .reconnecting
        let uptime = c.connectedAt.map { String(format: " after %.0fs", Date().timeIntervalSince($0)) } ?? ""
        let reason = error.map { ": \($0.localizedDescription)" } ?? ""
        append("\(c.kind.rawValue) disconnected\(uptime)\(reason) (#\(c.disconnects)) – reconnecting")
        refresh()
        // A pending connect never times out; CoreBluetooth reconnects as soon as the controller advertises.
        central.connect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension ControllerManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let c = known[peripheral.identifier] else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == c.kind.service }) else {
            append("Zwift service not found – update firmware in Zwift Companion")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Zwift.asyncChar, Zwift.syncRxChar, Zwift.syncTxChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let c = known[peripheral.identifier], let chars = service.characteristics else { return }
        let async = chars.first { $0.uuid == Zwift.asyncChar }
        let syncTx = chars.first { $0.uuid == Zwift.syncTxChar }
        c.syncRx = chars.first { $0.uuid == Zwift.syncRxChar }
        guard let async, let syncTx, c.syncRx != nil else {
            append("Zwift characteristics missing")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: async)
        peripheral.setNotifyValue(true, for: syncTx) // handshake is sent once this is confirmed
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = known[peripheral.identifier] else { return }
        if let error {
            append("Subscribe failed: \(error.localizedDescription)")
            return
        }
        // Subscribe first, then say "RideOn".
        guard characteristic.uuid == Zwift.syncTxChar, c.state != .ready else { return }
        c.kind.handshake.forEach { write($0, to: c) }
        c.state = .ready
        c.loggedVendorMessage = false
        append("\(c.kind.rawValue) ready – press a button")
        refresh()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = known[peripheral.identifier], let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        switch ZwiftParser.parse(bytes, kind: c.kind) {
        case let .buttons(buttons, unknownBits):
            handle(buttons, unknownBits: unknownBits, on: c)
        case let .battery(level):
            if c.battery != level { c.battery = level; refresh() }
        case .vendorMessage:
            // Logged for diagnosis only. (Earlier versions reset the device here, which caused reconnect loops.)
            if !c.loggedVendorMessage {
                c.loggedVendorMessage = true
                logFile.write("vendor message: \(Self.hex(bytes))")
            }
        case .ignored:
            break
        }
    }
}

/// Keeps the latest `maxLines` log lines in ~/Library/Logs/ClickShift.log, under a fixed header line.
final class FileLog {
    static let maxLines = 100
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClickShift.log")
    static let displayPath = "~/Library/Logs/ClickShift.log"
    static let header = "Only the latest \(maxLines) lines are kept. Log file: \(displayPath)"

    private var lines: [String]

    init() {
        let existing = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        lines = existing.split(separator: "\n").map(String.init).filter { $0 != Self.header }.suffix(Self.maxLines)
        write("---- ClickShift started ----")
    }

    func write(_ line: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        lines.append("\(ts) \(line)")
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        let text = ([Self.header] + lines).joined(separator: "\n") + "\n"
        try? text.write(to: Self.url, atomically: true, encoding: .utf8)
    }
}
