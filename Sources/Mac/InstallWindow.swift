import AppKit
import Carbon
import SwiftUI

final class InstallWindow: ObservableObject {
    static let shared = InstallWindow()
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)
    private var window: NSWindow?
    @Published private(set) var installed = false
    @Published private(set) var failed = false

    static var isInstalledBundle: Bool {
        let current = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return current == folder.resolvingSymlinksInPath() ||
            current == URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true).resolvingSymlinksInPath()
    }

    func open() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: InstallerView(model: self)))
        window.title = "安装 WA 五笔"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.styleMask.remove(.resizable)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func install() {
        let files = FileManager.default
        let source = Bundle.main.bundleURL
        let destination = Self.folder.appendingPathComponent("WA 五笔.app", isDirectory: true)
        let staging = Self.folder.appendingPathComponent(".wawubi-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: source, to: staging)
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staging, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try files.moveItem(at: staging, to: destination)
            }
            _ = TISRegisterInputSource(destination as CFURL)
            installed = true
            failed = false
        } catch { failed = true }
    }
}

private struct InstallerView: View {
    @ObservedObject var model: InstallWindow
    private let green = Color(red: 0.23, green: 0.51, blue: 0.41)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("五")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(green, in: RoundedRectangle(cornerRadius: 14))
            Text(model.installed ? "WA 五笔已安装" : "安装 WA 五笔")
                .font(.system(size: 27, weight: .bold))
            if model.installed {
                Text("在「系统设置 → 键盘 → 文本输入」中添加 WA 五笔。若列表未刷新，保存工作后注销并重新登录。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("完成") { NSApp.terminate(nil) }
                    Spacer()
                    Button("打开键盘设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("将原生 86 五笔输入法安装到当前用户。")
                    .foregroundStyle(.secondary)
                if model.failed { Text("安装失败，请检查当前用户的「Input Methods」目录。").foregroundStyle(.red) }
                HStack {
                    Button("取消") { NSApp.terminate(nil) }
                    Spacer()
                    Button("安装") { model.install() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(29)
        .frame(width: 435, alignment: .leading)
        .tint(green)
    }
}
