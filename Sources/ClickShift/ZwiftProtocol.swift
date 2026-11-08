import CoreBluetooth
import Foundation

/// Zwift controller BLE protocol.
/// Unencrypted "RideOn" mode only.
enum Zwift {
    static let manufacturerID: UInt16 = 0x094A // Zwift, Inc.

    static let clickService = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
    static let rideService = CBUUID(string: "FC82") // used by Click v2 / Ride
    static let asyncChar = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
    static let syncRxChar = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1") // we write here
    static let syncTxChar = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1") // indications

    static let rideOn: [UInt8] = Array("RideOn".utf8)
}

enum ControllerKind: String {
    case clickV1 = "Zwift Click"
    case clickV2 = "Zwift Click v2"

    /// Manufacturer data = [companyID lo, companyID hi, deviceType, ...]
    static func from(manufacturerData data: Data) -> ControllerKind? {
        let b = [UInt8](data)
        guard b.count >= 3, UInt16(b[0]) | (UInt16(b[1]) << 8) == Zwift.manufacturerID else { return nil }
        switch b[2] {
        case 0x09: return .clickV1
        // Only the LEFT Click v2 unit is connected; it relays the right one.
        case 0x0B: return .clickV2
        default: return nil
        }
    }

    var service: CBUUID { self == .clickV1 ? Zwift.clickService : Zwift.rideService }

    var handshake: [[UInt8]] {
        switch self {
        case .clickV1: return [Zwift.rideOn]
        case .clickV2: return [Zwift.rideOn, [0xFF, 0x04, 0x00]]
        }
    }
}

/// The mappable buttons. Click v1 only has + and −.
enum ControllerButton: String, CaseIterable, Identifiable {
    case plus, minus
    case navUp, navDown, navLeft, navRight
    case a, b, y, z

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plus: "+"; case .minus: "−"
        case .navUp: "D-pad up"; case .navDown: "D-pad down"; case .navLeft: "D-pad left"; case .navRight: "D-pad right"
        case .a: "A"; case .b: "B"; case .y: "Y"; case .z: "Z"
        }
    }

    /// Label used inside a titled section ("D-pad" → "Up").
    var shortTitle: String {
        switch self {
        case .navUp: "Up"; case .navDown: "Down"; case .navLeft: "Left"; case .navRight: "Right"
        default: title
        }
    }

    static func buttons(for kind: ControllerKind) -> [ControllerButton] {
        kind == .clickV1 ? [.plus, .minus] : allCases
    }

    /// Ride-protocol buttonMap bits (cleared = pressed). Right-side shift/power-up buttons count as +,
    /// left-side ones as −. On/off bits are known but ignored.
    static let rideBits: [(mask: UInt64, button: ControllerButton?)] = [
        (0x00001, .navLeft), (0x00002, .navUp), (0x00004, .navRight), (0x00008, .navDown),
        (0x00010, .a), (0x00020, .b), (0x00040, .y), (0x00080, .z),
        (0x00100, .minus), (0x00200, .minus), (0x00400, .minus), (0x00800, nil), // left shift up/down, power-up, on/off
        (0x01000, .plus), (0x02000, .plus), (0x04000, .plus), (0x08000, nil),    // right shift up/down, power-up, on/off
    ]
}

enum ParsedMessage {
    case buttons(Set<ControllerButton>, unknownBits: UInt64)
    case battery(Int)
    case vendorMessage
    case ignored
}

// MARK: - Parsing

enum ZwiftParser {
    static func parse(_ bytes: [UInt8], kind: ControllerKind) -> ParsedMessage {
        guard let type = bytes.first else { return .ignored }
        if bytes.starts(with: Zwift.rideOn) { return .ignored } // handshake reply
        let body = Array(bytes.dropFirst())

        switch kind {
        case .clickV1:
            switch type {
            case 0x37: return parseClickV1(body)            // CLICK_NOTIFICATION
            case 0x19: return body.count > 1 ? .battery(Int(body[1])) : .ignored
            default: return .ignored
            }
        case .clickV2:
            if type == 0xFF { return .vendorMessage }
            switch type {
            case 0x23: return parseRide(body)               // Opcode.CONTROLLER_NOTIFICATION
            case 0x19:                                      // Opcode.BATTERY_NOTIF
                let f = Proto.fields(body)
                if let level = f.first(where: { $0.number == 2 })?.varint { return .battery(Int(level)) }
                return .ignored
            default: return .ignored
            }
        }
    }

    /// ClickKeyPadStatus { PlayButtonStatus plus = 1; PlayButtonStatus minus = 2; } ON = 0, OFF = 1.
    /// proto3 omits default (0 = ON) values, so a missing field means "pressed".
    static func parseClickV1(_ body: [UInt8]) -> ParsedMessage {
        let f = Proto.fields(body)
        var pressed = Set<ControllerButton>()
        if (f.first(where: { $0.number == 1 })?.varint ?? 0) == 0 { pressed.insert(.plus) }
        if (f.first(where: { $0.number == 2 })?.varint ?? 0) == 0 { pressed.insert(.minus) }
        return .buttons(pressed, unknownBits: 0)
    }

    /// RideKeyPadStatus { uint32 buttonMap = 1; repeated RideAnalogKeyPress paddles = 3; }
    static func parseRide(_ body: [UInt8]) -> ParsedMessage {
        let f = Proto.fields(body)
        guard let map = f.first(where: { $0.number == 1 })?.varint else { return .buttons([], unknownBits: 0) }

        var pressed = Set(ControllerButton.rideBits.filter { map & $0.mask == 0 }.compactMap(\.button))
        // Cleared bits we don't know about, within the low 16 bits (rest are unused/always set).
        let known = ControllerButton.rideBits.reduce(UInt64(0)) { $0 | $1.mask }
        let unknown = ~map & 0xFFFF & ~known

        for paddle in f where paddle.number == 3 {
            guard let sub = paddle.bytes else { continue }
            let pf = Proto.fields(sub)
            let location = pf.first(where: { $0.number == 1 })?.varint ?? 0
            let raw = pf.first(where: { $0.number == 2 })?.varint ?? 0
            let value = Int64(raw >> 1) ^ -Int64(raw & 1) // sint32 zigzag
            if abs(value) >= 25 {
                if location == 0 { pressed.insert(.minus) }
                if location == 1 { pressed.insert(.plus) }
            }
        }
        return .buttons(pressed, unknownBits: unknown)
    }
}

// MARK: - Minimal protobuf reader

enum Proto {
    struct Field { let number: Int; let varint: UInt64?; let bytes: [UInt8]? }

    static func fields(_ b: [UInt8]) -> [Field] {
        var out: [Field] = []
        var i = 0
        while i < b.count {
            guard let key = varint(b, &i) else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint(b, &i) else { return out }
                out.append(Field(number: number, varint: v, bytes: nil))
            case 2:
                guard let len = varint(b, &i), i + Int(len) <= b.count else { return out }
                out.append(Field(number: number, varint: nil, bytes: Array(b[i..<i + Int(len)])))
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
