import Foundation
import IOKit
import IOKit.serial

/// A serial port (`/dev/cu.*`) with the USB identity of the adapter behind it,
/// so the rig's CAT cable can be told apart from Bluetooth/debug ports.
public struct SerialPort: Sendable, Identifiable {
    public let path: String          // /dev/cu.usbserial-...
    public let usbVendor: String?    // e.g. "FTDI"
    public let usbProduct: String?   // e.g. "Dual RS232-HS"
    public let vendorID: Int?
    public let productID: Int?

    public var id: String { path }

    /// Heuristic: a USB-serial bridge or rig-vendor port (the kind a CAT cable
    /// uses), excluding Bluetooth/debug and non-rig USB gadgets (monitors, etc.).
    public var likelyRig: Bool {
        let p = path.lowercased()
        if p.contains("bluetooth") || p.contains("debug") { return false }
        let text = ((usbVendor ?? "") + " " + (usbProduct ?? "")).lowercased()

        // Obvious non-rigs that also expose a serial/HID interface.
        let nonRig = ["monitor", "display", "keyboard", "mouse", "webcam",
                      "camera", "lg electronics", "touch"]
        if nonRig.contains(where: text.contains) { return false }

        // Common USB-serial bridge chips and rig manufacturers.
        let serialBridge = ["ftdi", "silicon labs", "cp210", "prolific", "pl2303",
                            "ch340", "ch341", "wch", "usb to uart", "usb-serial",
                            "usb serial", "rs232", "uart"]
        let rigVendor = ["icom", "yaesu", "kenwood", "elecraft", "flexradio", "flex radio"]
        if serialBridge.contains(where: text.contains) || rigVendor.contains(where: text.contains) {
            return true
        }
        // Fallback: a /dev/cu.usbserial-* device is almost always an adapter.
        return p.contains("usbserial")
    }

    /// One-line description for the picker.
    public var detail: String {
        var bits: [String] = []
        if let product = usbProduct { bits.append(product) }
        if let vendor = usbVendor { bits.append(vendor) }
        if bits.isEmpty, vendorID != nil || productID != nil {
            bits.append(String(format: "USB %04x:%04x", vendorID ?? 0, productID ?? 0))
        }
        if likelyRig { bits.append("likely rig CAT") }
        return bits.isEmpty ? "serial port" : bits.joined(separator: " · ")
    }
}

public enum SerialPorts {
    public static func list() -> [SerialPort] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var ports: [SerialPort] = []
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let path = stringProperty(service, kIOCalloutDeviceKey) {
                let usb = usbInfo(startingAt: service)
                ports.append(SerialPort(path: path,
                                        usbVendor: usb.vendor, usbProduct: usb.product,
                                        vendorID: usb.vid, productID: usb.pid))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        // Likely-rig ports first, then alphabetical.
        return ports.sorted { ($0.likelyRig ? 0 : 1, $0.path) < ($1.likelyRig ? 0 : 1, $1.path) }
    }

    // Walk up the IORegistry to the USB device for vendor/product strings + IDs.
    private static func usbInfo(startingAt service: io_object_t)
        -> (vendor: String?, product: String?, vid: Int?, pid: Int?) {
        var vendor: String?, product: String?, vid: Int?, pid: Int?
        var entry = service
        IOObjectRetain(entry)
        var depth = 0
        while entry != 0 && depth < 12 {
            vendor = vendor ?? stringProperty(entry, "USB Vendor Name")
            product = product ?? stringProperty(entry, "USB Product Name")
            vid = vid ?? intProperty(entry, "idVendor")
            pid = pid ?? intProperty(entry, "idProduct")
            if vendor != nil, product != nil, vid != nil, pid != nil { break }

            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = (kr == KERN_SUCCESS) ? parent : 0
            depth += 1
        }
        if entry != 0 { IOObjectRelease(entry) }
        return (vendor, product, vid, pid)
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return cf as? String
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (cf as? NSNumber)?.intValue
    }
}
