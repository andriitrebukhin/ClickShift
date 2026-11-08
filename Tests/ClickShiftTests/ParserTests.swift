import Foundation
import Testing
@testable import ClickShift

// MARK: - Helpers

/// Encodes a protobuf varint.
func varint(_ value: UInt64) -> [UInt8] {
    var v = value
    var out: [UInt8] = []
    while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
    out.append(UInt8(v))
    return out
}

/// Click v2 / Ride controller notification: opcode 0x23, field 1 = button map, field 3 = paddles.
func rideMessage(map: UInt64, paddles: [(location: UInt64, value: Int64)] = []) -> [UInt8] {
    var bytes: [UInt8] = [0x23, 0x08] + varint(map)
    for p in paddles {
        let zigzag = UInt64(bitPattern: (p.value << 1) ^ (p.value >> 63))
        let sub: [UInt8] = [0x08] + varint(p.location) + [0x10] + varint(zigzag)
        bytes += [0x1A] + varint(UInt64(sub.count)) + sub
    }
    return bytes
}

/// All 18 low bits set = nothing pressed (a cleared bit means "pressed").
let released: UInt64 = 0x3FFFF

func buttons(_ m: ParsedMessage) -> Set<ControllerButton>? {
    if case let .buttons(b, _) = m { return b }
    return nil
}

func battery(_ m: ParsedMessage) -> Int? {
    if case let .battery(level) = m { return level }
    return nil
}

func isIgnored(_ m: ParsedMessage) -> Bool {
    if case .ignored = m { return true }
    return false
}

// MARK: - Device detection

@Suite struct DeviceDetection {
    @Test func clickV1() {
        #expect(ControllerKind.from(manufacturerData: Data([0x4A, 0x09, 0x09])) == .clickV1)
    }

    @Test func clickV2LeftUnit() {
        #expect(ControllerKind.from(manufacturerData: Data([0x4A, 0x09, 0x0B, 0x01])) == .clickV2)
    }

    @Test(arguments: [
        [0x4A, 0x09, 0x0A],       // Click v2 right unit: relayed by the left one, not connected directly
        [0x4A, 0x09, 0x02],       // Zwift Play (unsupported)
        [0x4A, 0x09, 0x07],       // Zwift Ride right (unsupported)
        [0x4B, 0x09, 0x09],       // wrong company ID
        [0x4A, 0x09],             // too short
        [],
    ] as [[UInt8]])
    func ignoredAdvertisements(_ bytes: [UInt8]) {
        #expect(ControllerKind.from(manufacturerData: Data(bytes)) == nil)
    }
}

// MARK: - Click v1

@Suite struct ClickV1Parsing {
    @Test func plusPressed() {
        // field 1 (plus) omitted = ON (proto3 default), field 2 (minus) = OFF
        #expect(buttons(ZwiftParser.parse([0x37, 0x10, 0x01], kind: .clickV1)) == [.plus])
    }

    @Test func minusPressed() {
        #expect(buttons(ZwiftParser.parse([0x37, 0x08, 0x01], kind: .clickV1)) == [.minus])
    }

    @Test func bothReleased() {
        #expect(buttons(ZwiftParser.parse([0x37, 0x08, 0x01, 0x10, 0x01], kind: .clickV1)) == [])
    }

    @Test func bothPressedWhenFieldsOmitted() {
        #expect(buttons(ZwiftParser.parse([0x37], kind: .clickV1)) == [.plus, .minus])
    }

    @Test func batteryLevel() {
        #expect(battery(ZwiftParser.parse([0x19, 0x08, 0x55], kind: .clickV1)) == 85)
    }

    @Test(arguments: [ControllerKind.clickV1, .clickV2])
    func handshakeReplyIgnored(kind: ControllerKind) {
        #expect(isIgnored(ZwiftParser.parse(Zwift.rideOn + [0x01, 0x03, 0xAA], kind: kind)))
    }

    @Test func emptyAndUnknownMessagesIgnored() {
        #expect(isIgnored(ZwiftParser.parse([], kind: .clickV1)))
        #expect(isIgnored(ZwiftParser.parse([0x15], kind: .clickV1)))
    }
}

// MARK: - Click v2 (Ride protocol)

@Suite struct ClickV2Parsing {
    @Test func nothingPressed() {
        #expect(buttons(ZwiftParser.parse(rideMessage(map: released), kind: .clickV2)) == [])
    }

    /// Every mapped bit, pressed on its own, yields exactly its button.
    @Test(arguments: ControllerButton.rideBits.filter { $0.button != nil }.map { ($0.mask, $0.button!) })
    func singleBit(mask: UInt64, expected: ControllerButton) {
        let parsed = ZwiftParser.parse(rideMessage(map: released & ~mask), kind: .clickV2)
        #expect(buttons(parsed) == [expected])
    }

    @Test func onOffButtonsAreIgnored() {
        #expect(buttons(ZwiftParser.parse(rideMessage(map: released & ~0x0800 & ~0x8000), kind: .clickV2)) == [])
    }

    @Test func leftSideIsMinusRightSideIsPlus() {
        let left = released & ~0x0100 & ~0x0200 & ~0x0400
        let right = released & ~0x1000 & ~0x2000 & ~0x4000
        #expect(buttons(ZwiftParser.parse(rideMessage(map: left), kind: .clickV2)) == [.minus])
        #expect(buttons(ZwiftParser.parse(rideMessage(map: right), kind: .clickV2)) == [.plus])
    }

    @Test func multipleButtons() {
        let map = released & ~0x0001 & ~0x0010 & ~0x1000 // D-pad left + A + right shift
        #expect(buttons(ZwiftParser.parse(rideMessage(map: map), kind: .clickV2)) == [.navLeft, .a, .plus])
    }

    @Test func paddlesAboveThreshold() {
        let msg = rideMessage(map: released, paddles: [(0, -50), (1, 30)])
        #expect(buttons(ZwiftParser.parse(msg, kind: .clickV2)) == [.minus, .plus])
    }

    @Test func paddlesBelowThresholdIgnored() {
        let msg = rideMessage(map: released, paddles: [(0, 24), (1, -10)])
        #expect(buttons(ZwiftParser.parse(msg, kind: .clickV2)) == [])
    }

    @Test func missingButtonMapMeansNothingPressed() {
        #expect(buttons(ZwiftParser.parse([0x23], kind: .clickV2)) == [])
    }

    @Test func batteryLevel() {
        // BatteryNotification: field 2 = percentage
        #expect(battery(ZwiftParser.parse([0x19, 0x08, 0x00, 0x10, 0x40], kind: .clickV2)) == 64)
    }

    @Test func vendorMessageIsNotTreatedAsButtons() {
        let parsed = ZwiftParser.parse([0xFF, 0x05, 0x00, 0xEA, 0x05, 0x19], kind: .clickV2)
        if case .vendorMessage = parsed {} else { Issue.record("expected .vendorMessage, got \(parsed)") }
    }
}

// MARK: - Protobuf reader

@Suite struct ProtoReader {
    @Test func multiByteVarint() {
        var i = 0
        #expect(Proto.varint([0xAC, 0x02], &i) == 300)
        #expect(i == 2)
    }

    @Test func truncatedVarintReturnsNil() {
        var i = 0
        #expect(Proto.varint([0x80, 0x80], &i) == nil)
    }

    @Test func truncatedLengthDelimitedFieldStops() {
        // field 3, length 10, but only 2 bytes follow
        let fields = Proto.fields([0x08, 0x01, 0x1A, 0x0A, 0x01, 0x02])
        #expect(fields.count == 1)
        #expect(fields.first?.varint == 1)
    }

    /// Random input must never crash the parser.
    @Test func garbageInputDoesNotCrash() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<2_000 {
            let bytes = (0..<Int(rng.next() % 40)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = ZwiftParser.parse(bytes, kind: .clickV1)
            _ = ZwiftParser.parse(bytes, kind: .clickV2)
        }
    }
}

/// Small deterministic RNG so the garbage test is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
