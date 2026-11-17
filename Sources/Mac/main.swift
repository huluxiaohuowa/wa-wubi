import AppKit
import InputMethodKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
let settings = CommandLine.arguments.contains("--settings")
if InstallWindow.isInstalledBundle || settings {
    let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
    let server = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
    if server == nil { fatalError("Unable to initialize InputMethodKit server") }
    if settings {
        DispatchQueue.main.async { SettingsWindow.shared.open() }
    }
    withExtendedLifetime(server) { application.run() }
} else {
    DispatchQueue.main.async { InstallWindow.shared.open() }
    application.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if InstallWindow.isInstalledBundle || CommandLine.arguments.contains("--settings") {
            _ = LibraryStore.shared
        }
    }
}
