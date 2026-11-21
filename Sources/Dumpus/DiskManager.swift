import Foundation
import IOKit
import DiskArbitration

struct DiskInfo: Identifiable, Hashable {
    let id: String          // BSD name of the whole disk, e.g. "disk10"
    let size: UInt64
    let model: String
    let volumeName: String
    let mediaKind: String   // "CD", "DVD", "BD" or ""
    let mounted: Bool
    let mountable: Bool     // has a file system that macOS can mount (TAR, RAR, ZIP need it)

    var devicePath: String { "/dev/\(id)" }

    var displayName: String {
        let label = !volumeName.isEmpty ? volumeName : (model.isEmpty ? "Unknown" : model)
        let details = [mediaKind, formatBytes(size)].filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(devicePath) — \(label) (\(details))"
    }
}

struct Volume {
    let bsdName: String
    let path: URL
    let fsType: String
    var name: String { path.lastPathComponent }
}

final class DiskManager: ObservableObject {
    @Published var disks: [DiskInfo] = []
    private var session: DASession?
    private var refreshPending = false

    init() {
        refresh()
        watch()
    }

    deinit {
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    func refresh() {
        disks = Self.listDisks()
    }

    // MARK: - Watch for media changes

    private func watch() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { _, ctx in DiskManager.changed(ctx) }, ctx)
        DARegisterDiskDisappearedCallback(s, nil, { _, ctx in DiskManager.changed(ctx) }, ctx)
        DARegisterDiskDescriptionChangedCallback(s, nil, nil, { _, _, ctx in DiskManager.changed(ctx) }, ctx)
        DASessionSetDispatchQueue(s, .main)
    }

    private static func changed(_ ctx: UnsafeMutableRawPointer?) {
        guard let ctx else { return }
        Unmanaged<DiskManager>.fromOpaque(ctx).takeUnretainedValue().scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    // MARK: - Disk list

    static func listDisks() -> [DiskInfo] {
        guard let matching = IOServiceMatching("IOMedia") as NSMutableDictionary? else { return [] }
        matching["Whole"] = true
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let mounts = mountTable()
        let session = DASessionCreate(kCFAllocatorDefault)
        var result: [DiskInfo] = []
        forEach(iterator) { entry in
            guard isPhysical(entry), !isSynthesized(entry),
                  let props = properties(of: entry),
                  let bsd = props["BSD Name"] as? String, bsd != "disk0" else { return }
            let names = [bsd] + descendantBSDNames(entry)
            let nameSet = Set(names)
            let mounted = mounts.filter { nameSet.contains($0.bsdName) }
            let fs = session.map { fileSystems(names, session: $0) } ?? (name: "", mountable: false)
            result.append(DiskInfo(
                id: bsd,
                size: props["Size"] as? UInt64 ?? 0,
                model: deviceModel(for: entry) ?? "",
                volumeName: fs.name,
                mediaKind: mediaKind(entry),
                mounted: !mounted.isEmpty,
                mountable: fs.mountable || mounted.contains { $0.fsType != "cddafs" }
            ))
        }
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func mediaKind(_ entry: io_object_t) -> String {
        if IOObjectConformsTo(entry, "IOCDMedia") != 0 { return "CD" }
        if IOObjectConformsTo(entry, "IODVDMedia") != 0 { return "DVD" }
        if IOObjectConformsTo(entry, "IOBDMedia") != 0 { return "BD" }
        return ""
    }

    /// The first volume name on the disk, and whether macOS can mount a file system on it.
    /// DiskArbitration knows both also when the disk is not mounted. Audio CD tracks do not count.
    private static func fileSystems(_ bsdNames: [String], session: DASession) -> (name: String, mountable: Bool) {
        var name = ""
        var mountable = false
        for bsd in bsdNames {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let desc = DADiskCopyDescription(disk) as? [String: Any],
                  desc[kDADiskDescriptionVolumeKindKey as String] as? String != "cddafs" else { continue }
            if desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true { mountable = true }
            if name.isEmpty, let volume = desc[kDADiskDescriptionVolumeNameKey as String] as? String {
                name = volume
            }
        }
        return (name, mountable)
    }

    // MARK: - Media details used by the dumper

    /// The device that holds the ISO image of the disk.
    /// A CD has raw 2352-byte sectors on the whole disk. Its 2048-byte data is in a partition:
    /// diskNs0 for linked data tracks (normal ISO 9660 CDs), else the first data track
    /// (for example diskNs1 on Mac CDs with a partition map). Other media: the whole disk.
    static func isoSource(for bsd: String) throws -> String {
        guard let entry = service(bsd) else { throw DumpError("\(bsd) not found") }
        defer { IOObjectRelease(entry) }
        guard IOObjectConformsTo(entry, "IOCDMedia") != 0 else { return bsd }

        var tracks: [(id: Int, bsd: String, blockSize: Int)] = []
        children(of: entry) { scheme in
            guard IOObjectConformsTo(scheme, "IOPartitionScheme") != 0 else { return }
            children(of: scheme) { part in
                guard IOObjectConformsTo(part, "IOMedia") != 0, let p = properties(of: part),
                      let name = p["BSD Name"] as? String else { return }
                tracks.append((p["Partition ID"] as? Int ?? -1, name, p["Preferred Block Size"] as? Int ?? 0))
            }
        }
        if let linked = tracks.first(where: { $0.id == 0 }) { return linked.bsd }
        if let data = tracks.sorted(by: { $0.id < $1.id }).first(where: { $0.blockSize == 2048 }) { return data.bsd }
        if tracks.isEmpty, properties(of: entry)?["Preferred Block Size"] as? Int == 2048 { return bsd }
        throw DumpError("No data track on this CD (audio CD?)")
    }

    static func exists(_ bsd: String) -> Bool {
        guard let entry = service(bsd) else { return false }
        IOObjectRelease(entry)
        return true
    }

    /// Mounted file systems on the disk, its partitions and synthesized (APFS) children.
    static func mountedVolumes(of bsd: String) -> [Volume] {
        guard let entry = service(bsd) else { return [] }
        defer { IOObjectRelease(entry) }
        let names = Set([bsd] + descendantBSDNames(entry))
        return mountTable().filter { names.contains($0.bsdName) }
    }

    /// Mounted volumes with files. Leaves out the "Audio CD" (cddafs) volume.
    static func dataVolumes(of bsd: String) -> [Volume] {
        mountedVolumes(of: bsd).filter { $0.fsType != "cddafs" }
    }

    static func mountTable() -> [Volume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 8
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        let n = getfsstat(buf, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard n > 0 else { return [] }
        return (0..<Int(n)).compactMap { i -> Volume? in
            var fs = buf[i]
            let from = cString(&fs.f_mntfromname)
            guard from.hasPrefix("/dev/disk") else { return nil }
            return Volume(bsdName: String(from.dropFirst(5)),
                          path: URL(fileURLWithPath: cString(&fs.f_mntonname), isDirectory: true),
                          fsType: cString(&fs.f_fstypename))
        }
    }

    // MARK: - IOKit helpers

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func service(_ bsd: String) -> io_object_t? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        return s == 0 ? nil : s
    }

    private static func forEach(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private static func children(of entry: io_object_t, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        forEach(iterator, body)
    }

    private static func descendantBSDNames(_ entry: io_object_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        forEach(iterator) { child in
            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  let name = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { return }
            names.append(name)
        }
        return names
    }

    private static func isPhysical(_ entry: io_object_t) -> Bool {
        var parent: io_object_t = 0
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOBlockStorageDevice") != 0 {
                guard let proto = properties(of: current)?["Protocol Characteristics"] as? [String: Any],
                      let interconnect = proto["Physical Interconnect"] as? String else { return true }
                return !["Disk Image", "Virtual Interface"].contains(interconnect)
            }
        }
        return false
    }

    private static func isSynthesized(_ entry: io_object_t) -> Bool {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        var className = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(parent, &className)
        return String(cString: className).contains("APFS")
    }

    private static func deviceModel(for entry: io_object_t) -> String? {
        var parent: io_object_t = 0
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(current)
            current = parent
            guard let props = properties(of: current) else { continue }
            if let model = props["Model"] as? Data {
                return String(data: model, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            }
            if let dc = props["Device Characteristics"] as? [String: Any],
               let name = dc["Product Name"] as? String {
                let vendor = (dc["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return vendor.isEmpty ? name : "\(vendor) \(name)"
            }
        }
        return nil
    }

    private static func properties(of entry: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_000_000)
}
