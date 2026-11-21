import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.github.tenox7.dumpus"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            running.first { $0 != NSRunningApplication.current }?.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Dumper.stopRunningTool()
    }
}

@main
struct DumpusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Dumpus", id: "main") {
            ContentView(appState: appState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button(appState.helperInstalled ? "Reinstall Disk Helper…" : "Install Disk Helper…") {
                    changeHelper(install: true)
                }
                .disabled(appState.busy)
                Button("Uninstall Disk Helper…") {
                    changeHelper(install: false)
                }
                .disabled(appState.busy || !appState.helperInstalled)
            }
        }
    }

    private func changeHelper(install: Bool) {
        appState.isError = false
        appState.status = install ? "Installing disk helper…" : "Removing disk helper…"
        DispatchQueue.global(qos: .userInitiated).async {
            let error = install ? Helper.install() : Helper.uninstall()
            DispatchQueue.main.async {
                appState.helperInstalled = Helper.isInstalled
                appState.status = error ?? (install ? "Disk helper installed: no more password prompts"
                                                    : "Disk helper removed")
                appState.isError = error != nil && error != "Cancelled"
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = "Ready"
    @Published var isError: Bool = false
    @Published var busy: Bool = false
    @Published var helperInstalled = Helper.isInstalled
    var cancelled: Bool = false
}
