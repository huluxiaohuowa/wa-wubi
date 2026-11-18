import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appliesUpdate = CommandLine.arguments.contains("--apply-update")
DispatchQueue.main.async {
    InstallWindow.shared.open()
    if appliesUpdate { InstallWindow.shared.install() }
}
application.run()
