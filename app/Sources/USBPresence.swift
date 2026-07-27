import Foundation
import IOKit
import IOKit.usb

/// Cheap check for whether the scanner is physically attached.
///
/// This exists so the app can poll for the scanner without repeatedly running
/// `scanimage -L`, which *opens the USB device* to enumerate it. Doing that
/// every few seconds contends with the scanner and makes the connection look
/// unstable -- devices drop out and reappear for no reason. Reading the IOKit
/// registry touches nothing on the bus and takes well under a millisecond.
enum USBPresence {

    static let canonVendorID = 0x1083

    /// PIDs where the P-215 family presents as a real scanner (SANE can drive it).
    static let scannerModePIDs: Set<Int> = [0x1641, 0x1646, 0x1659, 0x165B, 0x164C,
                                            0x165F, 0x162C]
    /// PIDs where it presents as USB mass storage (CaptureOnTouch Lite mode).
    static let storageModePIDs: Set<Int> = [0x1647, 0x165C, 0x1660, 0x164E, 0x162D]

    enum Mode: Equatable {
        case absent
        case scanner(pid: Int)
        case storage(pid: Int)
        case unknown(pid: Int)

        var isAttached: Bool { self != .absent }
    }

    static func scannerMode() -> Mode {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return .absent }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return .absent }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard intProperty(service, "idVendor") == canonVendorID,
                  let pid = intProperty(service, "idProduct") else { continue }
            if scannerModePIDs.contains(pid) { return .scanner(pid: pid) }
            if storageModePIDs.contains(pid) { return .storage(pid: pid) }
            return .unknown(pid: pid)
        }
        return .absent
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (raw as? NSNumber)?.intValue
    }
}
