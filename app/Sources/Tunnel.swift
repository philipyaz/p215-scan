import Foundation

/// SCSI transport for the Canon P-215II while it is in CaptureOnTouch Lite mode
/// (Auto Start = ON, USB 1083:165c).
///
/// The scanner exposes a synthetic FAT16 volume whose two 2 MiB files are
/// windows onto the device's command buffer. The firmware snoops writes to the
/// blocks backing them:
///
///     transfer.dat  0x00  24-byte command block (12-byte header + 12-byte CDB)
///                   0x18  4-byte status doorbell
///                   0x1C  data-out block, payload at 0x28
///     INDATA.dat    0x00  data-in payload
///
/// Reverse engineered from CaptureOnTouch Lite Launcher.app; see reference/protocol/PROTOCOL.md.
final class Tunnel {

    enum Failure: Error, CustomStringConvertible {
        case volumeMissing
        case openFailed(String, Int32)
        case timeout
        case shortRead(Int, Int)
        case status(UInt32, UInt8)
        case checkCondition(key: UInt8, asc: UInt8, ascq: UInt8, info: UInt32)
        case cdbTooLong

        var description: String {
            switch self {
            case .volumeMissing:
                return "The scanner volume is not mounted. Connect the scanner with "
                     + "Auto Start set to ON."
            case .openFailed(let p, let e):
                return "Could not open \(p): \(String(cString: strerror(e)))"
            case .timeout:
                return "The scanner did not respond (doorbell timeout)."
            case .shortRead(let got, let want):
                return "Short read: got \(got) of \(want) bytes."
            case .status(let s, let op):
                return String(format: "Device status 0x%x for opcode 0x%02x", s, op)
            case .checkCondition(let k, let a, let q, _):
                return String(format: "Check condition: key 0x%x asc 0x%02x ascq 0x%02x", k, a, q)
            case .cdbTooLong:
                return "CDB longer than 12 bytes cannot be sent over this transport."
            }
        }

        /// Sense conditions that mean "the page/batch ended", not a real error.
        var isEndOfPaper: Bool {
            if case .checkCondition(let key, let asc, let ascq, _) = self {
                // 0x00/0x00 no additional info + key 0 handled elsewhere.
                // 0x3A = medium not present, 0x80 = Canon "no more documents".
                if key == 0x08 { return true }                    // BLANK CHECK
                if asc == 0x3A { return true }                    // medium not present
                if asc == 0x80 && ascq == 0x02 { return true }    // Canon: hopper empty
            }
            return false
        }
    }

    static let volume = "/Volumes/ONTOUCHLITE"
    static let inDataPath = volume + "/INDATA.dat"
    static let transferPath = volume + "/transfer.dat"

    private static let windowSize = 2 * 1024 * 1024
    private static let doorbellOffset: off_t = 0x18
    private static let dataOutOffset: off_t = 0x1C
    private static let busy: UInt32 = 0xFFFF_FFFF
    private static let fGlobalNoCache: Int32 = 55
    private static let pollInterval: useconds_t = 100_000   // 100 ms

    /// Opcodes for which the firmware does not raise the doorbell after the
    /// command block. All but START STOP UNIT are data-out commands, where the
    /// doorbell is rung after the data phase instead.
    private static let noDoorbell: Set<UInt8> = [0x15, 0x1B, 0x24, 0x2A, 0xD6, 0xE1]

    private var fdIn: Int32 = -1
    private var fdTransfer: Int32 = -1
    private var savedModes: [Int32: mode_t] = [:]

    /// Seconds to wait for the device to answer the doorbell.
    var timeout: TimeInterval = 30

    private(set) var lastStatus: UInt32 = 0

    static var volumeIsMounted: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: volume, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    // MARK: - Session

    private func openOne(_ path: String) throws -> Int32 {
        let fd = path.withCString { Darwin.open($0, O_RDWR | O_SYNC) }
        guard fd >= 0 else { throw Failure.openFailed(path, errno) }
        _ = fcntl(fd, Tunnel.fGlobalNoCache, 1)
        var st = stat()
        if fstat(fd, &st) == 0, fchmod(fd, 0) == 0 {
            // Locks Finder/Spotlight out for the duration of the session.
            // msdosfs ignores per-file modes, in which case this is a no-op.
            savedModes[fd] = st.st_mode
        }
        return fd
    }

    func open() throws {
        guard Tunnel.volumeIsMounted else { throw Failure.volumeMissing }
        fdIn = try openOne(Tunnel.inDataPath)
        fdTransfer = try openOne(Tunnel.transferPath)
        // Wipe the data-in window, exactly as Canon's OpenSession does.
        lseek(fdIn, 0, SEEK_SET)
        let zeros = [UInt8](repeating: 0, count: Tunnel.windowSize)
        zeros.withUnsafeBytes { _ = write(fdIn, $0.baseAddress, $0.count) }
    }

    func close() {
        // Make sure no scan is left running. A half-finished scan leaves the
        // firmware waiting on reads that never come, which blocks every later
        // access to the volume.
        if fdTransfer >= 0, fdIn >= 0 {
            let saved = timeout
            timeout = 3
            _ = try? execute([0xD8, 0x00, 0x00, 0x00, 0x00, 0x00])
            timeout = saved
        }
        if fdTransfer >= 0 {
            lseek(fdTransfer, 0, SEEK_SET)
            let zeros = [UInt8](repeating: 0, count: 512)
            zeros.withUnsafeBytes { _ = write(fdTransfer, $0.baseAddress, $0.count) }
            if let m = savedModes[fdTransfer] { _ = fchmod(fdTransfer, m) }
            Darwin.close(fdTransfer)
            fdTransfer = -1
        }
        if fdIn >= 0 {
            if let m = savedModes[fdIn] { _ = fchmod(fdIn, m) }
            Darwin.close(fdIn)
            fdIn = -1
        }
        savedModes.removeAll()
    }

    deinit { close() }

    // MARK: - Framing

    /// 12-byte message prefix shared by command (type 1) and data-out (type 2).
    private func header(payloadLength: Int, type: UInt16, tag: UInt16) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 12)
        let len = UInt32(payloadLength + 8).bigEndian
        withUnsafeBytes(of: len) { h.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: type.bigEndian) { h.replaceSubrange(4..<6, with: $0) }
        withUnsafeBytes(of: tag.bigEndian) { h.replaceSubrange(6..<8, with: $0) }
        return h
    }

    private func writeCommand(_ cdb: [UInt8]) throws {
        guard cdb.count <= 12 else { throw Failure.cdbTooLong }
        var block = header(payloadLength: 12, type: 1, tag: 0x9000)
        block += cdb + [UInt8](repeating: 0, count: 12 - cdb.count)
        precondition(block.count == 24)
        lseek(fdTransfer, 0, SEEK_SET)
        block.withUnsafeBytes { _ = write(fdTransfer, $0.baseAddress, $0.count) }
    }

    private func ringAndWait() throws -> UInt32 {
        lseek(fdTransfer, Tunnel.doorbellOffset, SEEK_SET)
        var sentinel = Tunnel.busy
        withUnsafeBytes(of: &sentinel) { _ = write(fdTransfer, $0.baseAddress, 4) }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lseek(fdTransfer, Tunnel.doorbellOffset, SEEK_SET)
            var status: UInt32 = Tunnel.busy
            let n = withUnsafeMutableBytes(of: &status) { read(fdTransfer, $0.baseAddress, 4) }
            if n == 4 && status != Tunnel.busy {
                lastStatus = status
                return status
            }
            if Date() > deadline { throw Failure.timeout }
            usleep(Tunnel.pollInterval)
        }
    }

    private func readIn(_ length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: length)
        lseek(fdIn, 0, SEEK_SET)
        let n = buf.withUnsafeMutableBytes { read(fdIn, $0.baseAddress, length) }
        if n < 0 { return [] }
        if n < length { buf.removeSubrange(n..<length) }
        return buf
    }

    // MARK: - SCSI

    /// Execute one SCSI command. Returns the data-in payload.
    @discardableResult
    func execute(_ cdb: [UInt8],
                 inLength: Int = 0,
                 dataOut: [UInt8]? = nil,
                 fetchSense: Bool = true) throws -> [UInt8] {
        try writeCommand(cdb)

        let status: UInt32
        if let payload = dataOut {
            var block = header(payloadLength: payload.count, type: 2, tag: 0xB000)
            block += payload
            lseek(fdTransfer, Tunnel.dataOutOffset, SEEK_SET)
            block.withUnsafeBytes { _ = write(fdTransfer, $0.baseAddress, $0.count) }
            status = try ringAndWait()
        } else if Tunnel.noDoorbell.contains(cdb[0]) {
            status = 0
            lastStatus = 0
        } else {
            status = try ringAndWait()
        }

        let data = readIn(inLength)

        if status != 0 {
            if fetchSense && cdb[0] != 0x03 {
                if let s = try? requestSense() {
                    throw Failure.checkCondition(key: s.key, asc: s.asc,
                                                 ascq: s.ascq, info: s.info)
                }
            }
            throw Failure.status(status, cdb[0])
        }
        return data
    }

    struct Sense {
        var key: UInt8, asc: UInt8, ascq: UInt8, info: UInt32
        var eom: Bool, ili: Bool
    }

    struct Outcome {
        var data: [UInt8]
        var status: UInt32
        var sense: Sense?
    }

    /// Like `execute`, but reports a non-zero status through the return value
    /// instead of throwing. The image READ loop needs this: the scanner signals
    /// both "not ready, ask again" and "end of page, here is the residue"
    /// through CHECK CONDITION, and in the latter case the data that did
    /// transfer is still wanted.
    func executeRaw(_ cdb: [UInt8], inLength: Int = 0,
                    dataOut: [UInt8]? = nil) throws -> Outcome {
        try writeCommand(cdb)

        let status: UInt32
        if let payload = dataOut {
            var block = header(payloadLength: payload.count, type: 2, tag: 0xB000)
            block += payload
            lseek(fdTransfer, Tunnel.dataOutOffset, SEEK_SET)
            block.withUnsafeBytes { _ = write(fdTransfer, $0.baseAddress, $0.count) }
            status = try ringAndWait()
        } else if Tunnel.noDoorbell.contains(cdb[0]) {
            status = 0
            lastStatus = 0
        } else {
            status = try ringAndWait()
        }

        let data = readIn(inLength)
        let sense = status != 0 ? try? requestSense() : nil
        return Outcome(data: data, status: status, sense: sense)
    }

    func requestSense() throws -> Sense {
        let raw = try execute([0x03, 0x00, 0x00, 0x00, 0x0E, 0x00],
                              inLength: 14, fetchSense: false)
        guard raw.count >= 14 else { throw Failure.shortRead(raw.count, 14) }
        let info = (UInt32(raw[3]) << 24) | (UInt32(raw[4]) << 16)
                 | (UInt32(raw[5]) << 8)  |  UInt32(raw[6])
        return Sense(key: raw[2] & 0x0F, asc: raw[12], ascq: raw[13], info: info,
                     eom: raw[2] & 0x40 != 0, ili: raw[2] & 0x20 != 0)
    }

    // MARK: - Identity

    struct Identity {
        var vendor: String, product: String, revision: String, firmware: String
        var peripheralType: UInt8
    }

    func inquiry() throws -> Identity {
        let raw = try execute([0x12, 0x00, 0x00, 0x00, 0x40, 0x00], inLength: 0x40)
        guard raw.count >= 36 else { throw Failure.shortRead(raw.count, 36) }
        func str(_ r: Range<Int>) -> String {
            let slice = raw[r.clamped(to: 0..<raw.count)]
            return String(decoding: slice, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\0", with: "")
        }
        return Identity(vendor: str(8..<16), product: str(16..<32),
                        revision: str(32..<36), firmware: str(40..<48),
                        peripheralType: raw[0] & 0x1F)
    }

    /// Canon's vendor capability page.
    struct Capabilities {
        var maxXres: Int, maxYres: Int
        var maxWidthPx: Int, maxLengthPx: Int
        /// Physical maximum at the sensor's native resolution.
        var maxWidthInches: Double { Double(maxWidthPx) / Double(max(maxXres, 1)) }
        var maxLengthInches: Double { Double(maxLengthPx) / Double(max(maxYres, 1)) }
    }

    func capabilities() throws -> Capabilities {
        let raw = try execute([0x12, 0x01, 0xF0, 0x00, 0x60, 0x00], inLength: 0x60)
        guard raw.count >= 32 else { throw Failure.shortRead(raw.count, 32) }
        func be16(_ i: Int) -> Int { Int(raw[i]) << 8 | Int(raw[i + 1]) }
        func be32(_ i: Int) -> Int {
            Int(raw[i]) << 24 | Int(raw[i + 1]) << 16 | Int(raw[i + 2]) << 8 | Int(raw[i + 3])
        }
        return Capabilities(maxXres: be16(5), maxYres: be16(7),
                            maxWidthPx: be32(20), maxLengthPx: be32(24))
    }

    func testUnitReady() throws {
        try execute([0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    struct Sensors { var raw: UInt8; var paperInFeeder: Bool; var cardInserted: Bool }

    func readSensors() throws -> Sensors {
        let r = try execute([0x28, 0x00, 0x8B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00],
                            inLength: 1)
        let b = r.first ?? 0
        return Sensors(raw: b, paperInFeeder: b & 0x01 != 0, cardInserted: b & 0x08 != 0)
    }
}
