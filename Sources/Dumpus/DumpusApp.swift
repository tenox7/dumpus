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
    }
}

class AppState: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = "Ready"
    @Published var isError: Bool = false
    @Published var busy: Bool = false
    var cancelled: Bool = false
}
