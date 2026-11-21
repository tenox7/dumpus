import Foundation
import DiskArbitration

struct DumpError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Mount, unmount and eject with DiskArbitration. The calls block: use them off the main thread.
enum DiskOps {
    private static let queue = DispatchQueue(label: "dumpus.diskarbitration")

    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var error: String?
    }

    private static let callback: DADiskMountCallback = { _, dissenter, ctx in
        let waiter = Unmanaged<Waiter>.fromOpaque(ctx!).takeRetainedValue()
        if let dissenter { waiter.error = DiskOps.describe(dissenter) }
        waiter.done.signal()
    }

    static func mount(_ bsd: String) throws {
        try perform(bsd, "Mount") { disk, ctx in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionWhole), callback, ctx)
        }
    }

    /// Unmounts every volume of the disk. Retries while the disk is busy.
    /// Forces only on read-only media (CD, DVD), where forcing cannot lose data.
    static func unmount(_ bsd: String) throws {
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            do {
                try unmountWhole(bsd, force: false)
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let error = lastError {
            guard !isWritable(bsd) else { throw error }
            try unmountWhole(bsd, force: true)
        }
        // Volumes of synthesized disks (APFS containers) are not part of the whole-disk unmount.
        for vol in DiskManager.mountedVolumes(of: bsd) {
            try perform(vol.bsdName, "Unmount \(vol.name)") { disk, ctx in
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, ctx)
            }
        }
    }

    static func eject(_ bsd: String) throws {
        if !DiskManager.mountedVolumes(of: bsd).isEmpty { try unmount(bsd) }
        try perform(bsd, "Eject") { disk, ctx in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, ctx)
        }
    }

    private static func unmountWhole(_ bsd: String, force: Bool) throws {
        let options = kDADiskUnmountOptionWhole | (force ? kDADiskUnmountOptionForce : 0)
        try perform(bsd, "Unmount") { disk, ctx in
            DADiskUnmount(disk, DADiskUnmountOptions(options), callback, ctx)
        }
    }

    private static func isWritable(_ bsd: String) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return true }
        return desc[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? true
    }

    private static func perform(_ bsd: String, _ what: String, timeout: Double = 60,
                                _ op: (DADisk, UnsafeMutableRawPointer) -> Void) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw DumpError("\(what): DiskArbitration failed") }
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            throw DumpError("\(what): \(bsd) not found")
        }
        let waiter = Waiter()
        op(disk, Unmanaged.passRetained(waiter).toOpaque())
        if waiter.done.wait(timeout: .now() + timeout) == .timedOut { throw DumpError("\(what) of \(bsd) timed out") }
        if let error = waiter.error { throw DumpError("\(what) of \(bsd) failed: \(error)") }
    }

    private static func describe(_ dissenter: DADissenter) -> String {
        if let text = DADissenterGetStatusString(dissenter) as String?, !text.isEmpty { return text }
        let status = UInt32(bitPattern: DADissenterGetStatus(dissenter))
        if status & 0xFFFF_C000 == 0xC000 { return String(cString: strerror(Int32(status & 0x3FFF))) }  // unix_err()
        switch status {
        case 0xF8DA_0002: return "disk is in use"
        case 0xF8DA_0004: return "disk is opened for exclusive access"
        case 0xF8DA_0007: return "not mounted"
        case 0xF8DA_0008: return "not permitted"
        case 0xF8DA_0009: return "not privileged"
        case 0xF8DA_000A: return "not ready"
        case 0xF8DA_000C: return "not supported"
        default: return String(format: "error 0x%08X", status)
        }
    }
}
