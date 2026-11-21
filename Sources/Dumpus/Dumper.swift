import Foundation
import Security
import CDumpus

enum DumpFormat: String, CaseIterable {
    case iso, tar, rar, zip
    var label: String { rawValue.uppercased() }
}

struct DumpJob {
    let disk: String        // BSD name of the whole disk
    let directory: URL
    let baseName: String
    let formats: [DumpFormat]
    let blockSize: Int
    let eject: Bool
}

extension DumpError {
    static let cancelled = DumpError("Cancelled")
}

final class Dumper {
    static let rarPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/rar", "/usr/local/bin/rar", "/opt/local/bin/rar", "\(home)/bin/rar", "/usr/bin/rar"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Folders that macOS makes on writable volumes. They are not part of the media.
    static let systemFolders: Set<String> = [
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    private static let queue = DispatchQueue(label: "dumpus.work", qos: .userInitiated)
    private static let runningLock = NSLock()
    private static var runningTool: Process?
    private static var authRef: AuthorizationRef?

    private let appState: AppState
    private var entryCounts: [String: (files: Int, dirs: Int)] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Operations (call on the main thread)

    func dump(_ job: DumpJob) {
        run { try self.perform(job) }
    }

    func mount(_ bsd: String) {
        run {
            self.setStatus("Mounting…")
            try DiskOps.mount(bsd)
            let paths = DiskManager.dataVolumes(of: bsd).map(\.path.path)
            return paths.isEmpty ? "Mounted" : "Mounted " + paths.joined(separator: ", ")
        }
    }

    func unmount(_ bsd: String) {
        run {
            self.setStatus("Unmounting…")
            if !DiskManager.mountedVolumes(of: bsd).isEmpty { try DiskOps.unmount(bsd) }
            return "Unmounted"
        }
    }

    func eject(_ bsd: String) {
        run {
            self.setStatus("Ejecting…")
            try DiskOps.eject(bsd)
            return "Ejected"
        }
    }

    static func stopRunningTool() {
        runningLock.lock()
        runningTool?.terminate()
        runningLock.unlock()
    }

    private func run(_ work: @escaping () throws -> String) {
        appState.busy = true
        appState.cancelled = false
        appState.isError = false
        appState.progress = 0
        Self.queue.async {
            var message: String
            var failed = false
            do {
                message = try work()
            } catch {
                message = (error as? DumpError)?.message ?? error.localizedDescription
                failed = message != DumpError.cancelled.message
            }
            DispatchQueue.main.async {
                self.appState.status = message
                self.appState.isError = failed
                self.appState.busy = false
            }
        }
    }

    // MARK: - Dump job

    private func perform(_ job: DumpJob) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: job.directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw DumpError("Folder not found: \(job.directory.path)")
        }

        // Archives need the volume mounted, the ISO needs it unmounted.
        // Start with the formats that match the state the disk is in now.
        let wasMounted = !DiskManager.mountedVolumes(of: job.disk).isEmpty
        let archives = job.formats.filter { $0 != .iso }
        let iso: [DumpFormat] = job.formats.contains(.iso) ? [.iso] : []
        let steps = wasMounted ? archives + iso : iso + archives

        var written: [String] = []
        var failure: DumpError?
        for (index, format) in steps.enumerated() {
            let tag = steps.count > 1 ? "\(format.label) \(index + 1)/\(steps.count)" : format.label
            do {
                if appState.cancelled { throw DumpError.cancelled }
                if format == .iso {
                    written.append(try dumpISO(job, tag: tag))
                } else {
                    written += try archive(format, job, tag: tag)
                }
            } catch {
                failure = error as? DumpError ?? DumpError("\(tag): \(error.localizedDescription)")
                break
            }
        }

        if failure == nil && job.eject {
            setStatus("Ejecting…")
            do {
                try DiskOps.eject(job.disk)
            } catch {
                failure = DumpError("Saved \(written.joined(separator: ", ")), but \((error as? DumpError)?.message ?? "eject failed")")
            }
        } else {
            restore(job.disk, mounted: wasMounted)
        }
        if let failure { throw failure }
        setProgress(1)
        let dir = (job.directory.path as NSString).abbreviatingWithTildeInPath
        return "Done: \(written.joined(separator: ", ")) in \(dir)"
    }

    /// Puts the disk back in the mount state it had before the job.
    private func restore(_ bsd: String, mounted: Bool) {
        let mountedNow = !DiskManager.mountedVolumes(of: bsd).isEmpty
        if mounted && !mountedNow {
            setStatus("Mounting…")
            try? DiskOps.mount(bsd)
        } else if !mounted && mountedNow {
            setStatus("Unmounting…")
            try? DiskOps.unmount(bsd)
        }
    }

    // MARK: - ISO

    private func dumpISO(_ job: DumpJob, tag: String) throws -> String {
        if !DiskManager.mountedVolumes(of: job.disk).isEmpty {
            setStatus("\(tag): unmounting…")
            try DiskOps.unmount(job.disk)
        }
        let path = "/dev/r" + (try DiskManager.isoSource(for: job.disk))
        setStatus("\(tag): opening \(path)…")
        let fd = try openDevice(path)
        defer { close(fd) }

        var sectorSize: UInt32 = 0
        var sectors: UInt64 = 0
        guard disk_geometry(fd, &sectorSize, &sectors) == 0, sectorSize > 0, sectors > 0 else {
            throw DumpError("\(tag): cannot get the size of \(path)")
        }
        let sector = Int(sectorSize)
        let total = UInt64(sector) * sectors
        let chunk = max(sector, job.blockSize / sector * sector)

        let url = job.directory.appendingPathComponent(job.baseName + ".iso")
        let out = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard out >= 0 else {
            let reason = errnoString()
            throw DumpError("\(tag): cannot create \(url.lastPathComponent): \(reason)")
        }
        var outOpen = true
        defer { if outOpen { close(out) } }
        guard let buf = valloc(chunk) else { throw DumpError("\(tag): out of memory") }
        defer { free(buf) }

        let start = Date()
        var lastReport = Date.distantPast
        var offset: UInt64 = 0
        while offset < total {
            let len = Int(min(UInt64(chunk), total - offset))
            let (got, err) = appState.cancelled ? (0, 0) : readBlock(fd, buf, len, offset, sector)
            if appState.cancelled {
                close(out)
                outOpen = false
                unlink(url.path)
                throw DumpError.cancelled
            }
            guard writeAll(out, buf, got) else {
                let reason = errnoString()
                throw DumpError("\(tag): write error: \(reason)")
            }
            offset += UInt64(got)
            if got < len {
                let reason = err == 0 ? "end of media" : String(cString: strerror(err))
                throw DumpError("\(tag): read error at sector \(offset / UInt64(sector)) of \(sectors) (\(reason)). "
                                + "\(formatBytes(offset)) saved in \(url.lastPathComponent)")
            }
            if Date().timeIntervalSince(lastReport) >= 0.25 || offset == total {
                lastReport = Date()
                reportISO(tag: tag, path: path, done: offset, total: total, start: start)
            }
        }
        outOpen = false
        guard close(out) == 0 else {
            let reason = errnoString()
            throw DumpError("\(tag): write error: \(reason)")
        }
        return url.lastPathComponent
    }

    /// Reads len bytes at offset. On error it tries again, then reads one sector at a time
    /// to keep the good data before the bad sector. Returns the bytes read and the errno.
    private func readBlock(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ len: Int,
                           _ offset: UInt64, _ sector: Int) -> (Int, Int32) {
        for _ in 0..<2 {
            if pread(fd, buf, len, off_t(offset)) == len { return (len, 0) }
        }
        var done = 0
        while done < len {
            var err: Int32 = 0
            var ok = false
            for _ in 0..<2 where !ok && !appState.cancelled {
                let n = pread(fd, buf + done, sector, off_t(offset) + off_t(done))
                ok = n == sector
                if n < 0 { err = errno }
            }
            if !ok { return (done, err) }
            done += sector
        }
        return (len, 0)
    }

    private func reportISO(tag: String, path: String, done: UInt64, total: UInt64, start: Date) {
        let elapsed = Date().timeIntervalSince(start)
        var text = "\(tag): \(formatBytes(done)) of \(formatBytes(total)) from \(path)"
        if elapsed > 1, done > 0 {
            let speed = Double(done) / elapsed
            text += String(format: ", %.1f MB/s", speed / 1_000_000)
            text += ", \(formatDuration(Double(total - done) / speed)) left"
        }
        setProgress(Double(done) / Double(total))
        setStatus(text)
    }

    private func writeAll(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = write(fd, buf + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            done += n
        }
        return true
    }

    // MARK: - Root access to the device (same as Dufus)

    private func openDevice(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { return fd }
        let err = errno
        guard err == EACCES || err == EPERM else {
            throw DumpError("Cannot open \(path): \(String(cString: strerror(err)))")
        }
        setStatus("Waiting for authorization to read \(path)…")
        return try authOpen(path)
    }

    private func authOpen(_ path: String) throws -> Int32 {
        if Self.authRef == nil {
            var ref: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess else {
                throw DumpError("Authorization failed")
            }
            Self.authRef = ref
        }
        guard let auth = Self.authRef else { throw DumpError("Authorization failed") }

        let right = "sys.openfile.readonly.\(path)"
        let status: OSStatus = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .extendRights], nil)
            }
        }
        if status == errAuthorizationCanceled { throw DumpError("Authorization cancelled") }
        guard status == errAuthorizationSuccess else { throw DumpError("Authorization failed (\(status))") }

        var extForm = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(auth, &extForm) == errAuthorizationSuccess else {
            throw DumpError("Authorization failed")
        }

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            let reason = errnoString()
            throw DumpError("socketpair: \(reason)")
        }

        let stdinPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        proc.arguments = ["-stdoutpipe", "-extauth", path]
        proc.standardOutput = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        proc.standardInput = stdinPipe
        do {
            try proc.run()
        } catch {
            close(fds[0])
            close(fds[1])
            throw DumpError("Cannot run authopen: \(error.localizedDescription)")
        }
        close(fds[1])

        withUnsafeBytes(of: &extForm) { stdinPipe.fileHandleForWriting.write(Data($0)) }
        stdinPipe.fileHandleForWriting.closeFile()

        let fd = recv_fd(fds[0])
        close(fds[0])
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, fd >= 0 else {
            if fd >= 0 { close(fd) }
            throw DumpError("authopen cannot open \(path)")
        }
        return fd
    }

    // MARK: - TAR, RAR, ZIP

    private func archive(_ format: DumpFormat, _ job: DumpJob, tag: String) throws -> [String] {
        var volumes = DiskManager.dataVolumes(of: job.disk)
        if volumes.isEmpty {
            setStatus("\(tag): mounting…")
            try DiskOps.mount(job.disk)
            var tries = 0
            while volumes.isEmpty && tries < 20 {
                volumes = DiskManager.dataVolumes(of: job.disk)
                if volumes.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
                tries += 1
            }
        }
        guard let first = volumes.first else { throw DumpError("\(tag): no volume with files on \(job.disk)") }
        volumes = volumes.filter { !topLevelItems($0.path).isEmpty }
        guard !volumes.isEmpty else { throw DumpError("\(tag): \(first.name) is empty") }

        // One volume: <name>.<ext>. More volumes: one archive each, <name>-<volume>.<ext>.
        var names: [String] = []
        for vol in volumes {
            let url = volumes.count == 1
                ? job.directory.appendingPathComponent("\(job.baseName).\(format.rawValue)")
                : uniqueURL(job.directory, "\(job.baseName)-\(sanitizeFileName(vol.name))", format.rawValue)
            try archiveVolume(format, vol, to: url, tag: tag)
            names.append(url.lastPathComponent)
        }
        return names
    }

    private struct Tool {
        let path: String
        let args: [String]
        let total: Int
        let isEntry: (String) -> Bool
        let isError: (String) -> Bool
    }

    private func archiveVolume(_ format: DumpFormat, _ vol: Volume, to url: URL, tag: String) throws {
        let root = vol.path
        let items = topLevelItems(root)
        guard !items.isEmpty else { throw DumpError("\(tag): \(vol.name) is empty") }
        if entryCounts[root.path] == nil {
            setStatus("\(tag): counting files on \(vol.name)…")
            entryCounts[root.path] = countEntries(root)
        }
        if appState.cancelled { throw DumpError.cancelled }
        let count = entryCounts[root.path] ?? (0, 0)
        unlink(url.path)  // rar and zip would add to an old archive

        let tool: Tool
        switch format {
        case .tar:
            tool = Tool(path: "/usr/bin/tar",
                        args: ["-c", "-v", "-f", url.path, "-C", root.path] + items,
                        total: count.files + count.dirs,
                        isEntry: { $0.hasPrefix("a ") },
                        isError: { $0.hasPrefix("tar: ") })
        case .zip:
            tool = Tool(path: "/usr/bin/zip",
                        args: ["-r", "-y", url.path] + items,
                        total: count.files + count.dirs,
                        isEntry: { $0.hasPrefix("adding: ") },
                        isError: { $0.hasPrefix("zip warning") || $0.hasPrefix("zip error") || $0.hasPrefix("zip I/O") })
        case .rar:
            guard let rar = Self.rarPath else { throw DumpError("\(tag): rar not found") }
            // Best compression, 16 GB dictionary, solid, recovery record (as in rarext).
            tool = Tool(path: rar,
                        args: ["a", "-m5", "-md16g", "-s", "-rr", "-r", "-ol", "-y", "-idcdp"]
                            + Self.systemFolders.sorted().map { "-x\($0)" } + ["--", url.path, "*"],
                        total: count.files + count.dirs,
                        isEntry: { $0.hasPrefix("Adding") },
                        isError: { $0.contains("ERROR") || $0.contains("WARNING") || $0.hasPrefix("Cannot") })
        case .iso:
            throw DumpError("\(tag): not an archive format")
        }

        let (code, lastError) = try runTool(tool, cwd: root, output: url, tag: tag)
        if appState.cancelled {
            unlink(url.path)
            throw DumpError.cancelled
        }
        guard code == 0 else {
            let name = URL(fileURLWithPath: tool.path).lastPathComponent
            throw DumpError("\(tag): \(name) failed with exit code \(code)" + (lastError.map { ": \($0)" } ?? ""))
        }
    }

    private func runTool(_ tool: Tool, cwd: URL, output: URL, tag: String) throws -> (Int32, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool.path)
        proc.arguments = tool.args
        proc.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"  // without a UTF-8 locale tar fails on non-ASCII file names
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let lines = LineReader(isEntry: tool.isEntry, isError: tool.isError)
        do {
            try proc.run()
        } catch {
            throw DumpError("\(tag): cannot run \(tool.path): \(error.localizedDescription)")
        }
        Self.runningLock.lock()
        Self.runningTool = proc
        Self.runningLock.unlock()
        defer {
            Self.runningLock.lock()
            Self.runningTool = nil
            Self.runningLock.unlock()
        }

        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                lines.feed(data)
            }
            reader.leave()
        }

        while proc.isRunning {
            if appState.cancelled { proc.terminate() }
            let done = lines.entries
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? UInt64) ?? 0
            setProgress(tool.total > 0 ? min(Double(done) / Double(tool.total), 0.99) : 0)
            setStatus("\(tag): \(done) of \(tool.total) files, \(formatBytes(size)) in \(output.lastPathComponent)")
            Thread.sleep(forTimeInterval: 0.25)
        }
        reader.wait()
        return (proc.terminationStatus, lines.lastError)
    }

    private final class LineReader {
        private let lock = NSLock()
        private var buffer = Data()
        private var count = 0
        private var error: String?
        private let isEntry: (String) -> Bool
        private let isError: (String) -> Bool

        init(isEntry: @escaping (String) -> Bool, isError: @escaping (String) -> Bool) {
            self.isEntry = isEntry
            self.isError = isError
        }

        var entries: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        var lastError: String? {
            lock.lock(); defer { lock.unlock() }
            return error
        }

        func feed(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            while let end = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(buffer.startIndex...end)
                if isEntry(line) {
                    count += 1
                } else if isError(line) {
                    error = line
                }
            }
        }
    }

    /// Counts what the archivers will list: files (and links) and folders.
    private func countEntries(_ root: URL) -> (files: Int, dirs: Int) {
        var files = 0
        var dirs = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else {
            return (0, 0)
        }
        for case let url as URL in walker {
            if appState.cancelled { break }
            if walker.level == 1 && Self.systemFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isSymbolicLink != true { dirs += 1 } else { files += 1 }
        }
        return (files, dirs)
    }

    /// Top-level names on the volume, without the macOS system folders.
    private func topLevelItems(_ root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !Self.systemFolders.contains($0) }.sorted()
            .map { $0.hasPrefix("-") || $0.hasPrefix("@") ? "./" + $0 : $0 }  // not options for tar and zip
    }

    private func uniqueURL(_ dir: URL, _ base: String, _ ext: String) -> URL {
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: - Status

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.appState.status = text }
    }

    private func setProgress(_ value: Double) {
        DispatchQueue.main.async { self.appState.progress = min(max(value, 0), 1) }
    }
}

func sanitizeFileName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "?" }
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func errnoString() -> String {
    String(cString: strerror(errno))
}
