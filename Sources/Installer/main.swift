import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
DispatchQueue.main.async { InstallWindow.shared.open() }
application.run()
