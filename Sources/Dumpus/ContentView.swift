import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState
    @StateObject private var diskManager = DiskManager()
    @State private var selectedID: String?
    @State private var knownIDs: Set<String>?
    @State private var fileName = ""
    @State private var autoName = ""
    @State private var replaceNames: [String] = []
    @State private var showReplace = false
    @AppStorage("outputDir") private var outputDir = ContentView.defaultDir
    @AppStorage("formatISO") private var iso = true
    @AppStorage("formatTLZ") private var tlz = false
    @AppStorage("formatRAR") private var rar = false
    @AppStorage("formatZIP") private var zip = false
    @AppStorage("blockSize") private var blockSize = 1 << 20
    @AppStorage("ejectWhenDone") private var ejectWhenDone = false
    private var dumper: Dumper { Dumper(appState: appState) }

    static let blockSizes = [2, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192].map { $0 << 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $selectedID) {
                    Text("Select a disk…").tag(nil as String?)
                    ForEach(diskManager.disks) { disk in
                        Text(disk.displayName).tag(disk.id as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button("⟳") { diskManager.refresh() }
            }
            .disabled(appState.busy)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Folder:").gridColumnAlignment(.trailing)
                    HStack {
                        Text((outputDir as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(outputDir)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                GridRow {
                    Text("Name:")
                    TextField("file name", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Format:")
                    HStack(spacing: 16) {
                        Toggle("ISO", isOn: $iso)
                        Toggle("TLZ", isOn: archive($tlz))
                            .disabled(!mountable)
                            .help(Dumper.plzipPath == nil ? "plzip not found, so TLZ writes .tar.gz. Install plzip for .tar.lz." : "")
                        Toggle("RAR", isOn: archive($rar, available: Dumper.rarPath != nil))
                            .disabled(!mountable || Dumper.rarPath == nil)
                            .help(Dumper.rarPath == nil ? "rar not found. Install it from rarlab.com." : "")
                        Toggle("ZIP", isOn: archive($zip))
                            .disabled(!mountable)
                    }
                    .toggleStyle(.checkbox)
                }
                if !mountable {
                    GridRow {
                        Text("")
                        Text("No file system that macOS can mount: ISO only.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                GridRow {
                    Text("Block size:")
                    Picker("", selection: $blockSize) {
                        ForEach(Self.blockSizes, id: \.self) { size in
                            Text(size >= 1 << 20 ? "\(size >> 20) MB" : "\(size >> 10) KB").tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!iso)
                }
            }
            .disabled(appState.busy)

            Toggle("Eject when done", isOn: $ejectWhenDone)
                .toggleStyle(.checkbox)
                .disabled(appState.busy)

            Spacer(minLength: 0)
            progressSection
            buttons
        }
        .padding(20)
        .frame(width: 420, height: 340)
        .onAppear { syncSelection() }
        .onChange(of: appState.isError) { failed in
            guard failed else { return }
            NSSound.beep()
            NSApp.requestUserAttention(.criticalRequest)
        }
        .onChange(of: diskManager.disks) { _ in syncSelection() }
        .onChange(of: selectedID) { _ in updateAutoName() }
        .alert("Replace existing files?", isPresented: $showReplace) {
            Button("Replace", role: .destructive) { launch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceNames.joined(separator: "\n"))
        }
    }

    private var progressSection: some View {
        Group {
            if appState.isError {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ERROR")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text(appState.status)
                            .font(.caption)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: appState.progress)
                        .scaleEffect(y: 4, anchor: .center)
                    Text(appState.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .bottomLeading)
    }

    private var buttons: some View {
        HStack {
            Button("Dump") { startDump() }
                .buttonStyle(.borderedProminent)
                .disabled(!canDump)
            Button("Stop") {
                appState.cancelled = true
                Dumper.stopRunningTool()
            }
            .disabled(!appState.busy)
            Spacer()
            Button("Mount") { selectedID.map { dumper.mount($0) } }
                .disabled(appState.busy || selectedDisk == nil || selectedDisk?.mounted == true || !mountable)
            Button("Unmount") { selectedID.map { dumper.unmount($0) } }
                .disabled(appState.busy || selectedDisk?.mounted != true)
            Button("Eject") { selectedID.map { dumper.eject($0) } }
                .disabled(appState.busy || selectedDisk == nil)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - State

    private var selectedDisk: DiskInfo? {
        diskManager.disks.first { $0.id == selectedID }
    }

    /// TLZ, RAR and ZIP need a file system that macOS can mount. Without a disk, keep them on.
    private var mountable: Bool {
        selectedDisk?.mountable ?? true
    }

    /// Shows an archive format as off when it cannot be used, but keeps the saved choice.
    private func archive(_ value: Binding<Bool>, available: Bool = true) -> Binding<Bool> {
        mountable && available ? value : .constant(false)
    }

    private var formats: [DumpFormat] {
        let rarOK = Dumper.rarPath != nil
        return [iso ? .iso : nil, tlz && mountable ? .tlz : nil, rar && rarOK && mountable ? .rar : nil,
                zip && mountable ? .zip : nil].compactMap { $0 }
    }

    /// The name without a dump extension the user may have typed.
    private var baseName: String {
        let name = sanitizeFileName(fileName)
        for ext in DumpFormat.knownExtensions where name.lowercased().hasSuffix("." + ext) {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }

    private var canDump: Bool {
        selectedDisk != nil && !formats.isEmpty && !baseName.isEmpty && !appState.busy
    }

    /// Keeps the selection valid. Selects a disk that was just inserted, or the only disk.
    private func syncSelection() {
        let ids = Set(diskManager.disks.map(\.id))
        let added = knownIDs.map { ids.subtracting($0) } ?? []
        knownIDs = ids
        if let id = selectedID, !ids.contains(id) { selectedID = nil }
        if !appState.busy {
            if let newDisk = diskManager.disks.last(where: { added.contains($0.id) }) {
                selectedID = newDisk.id
            } else if selectedID == nil, diskManager.disks.count == 1 {
                selectedID = diskManager.disks.first?.id
            }
        }
        updateAutoName()
    }

    /// Fills the name from the volume name, unless the user typed their own name.
    private func updateAutoName() {
        let name = sanitizeFileName(selectedDisk?.volumeName ?? "")
        if fileName.isEmpty || fileName == autoName { fileName = name }
        autoName = name
    }

    // MARK: - Actions

    private func startDump() {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        replaceNames = formats.map { "\(baseName).\($0.ext)" }
            .filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if replaceNames.isEmpty {
            launch()
        } else {
            showReplace = true
        }
    }

    private func launch() {
        guard let disk = selectedID, canDump else { return }
        dumper.dump(DumpJob(
            disk: disk,
            directory: URL(fileURLWithPath: outputDir, isDirectory: true),
            baseName: baseName,
            formats: formats,
            blockSize: blockSize,
            eject: ejectWhenDone
        ))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url.path
        }
    }

    static let defaultDir: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? NSHomeDirectory() + "/Downloads"
}
