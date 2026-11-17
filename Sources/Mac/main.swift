import AppKit
import InputMethodKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
if server == nil { fatalError("Unable to initialize InputMethodKit server") }
if CommandLine.arguments.contains("--settings") {
    DispatchQueue.main.async { SettingsWindow.shared.open() }
}
withExtendedLifetime(server) { application.run() }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LibraryStore.shared
        Task { @MainActor in UpdateManager.shared.start() }
    }
}
