import AppKit
import Carbon
import SwiftUI

final class InstallWindow: ObservableObject {
    static let shared = InstallWindow()
    private var window: NSWindow?
    @Published private(set) var installed = false
    @Published private(set) var installing = false
    @Published private(set) var error: String?

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
        guard !installing, !installed else { return }
        guard let archive = Bundle.main.url(forResource: "WAWubi", withExtension: "zip") else {
            error = "安装器缺少输入法文件，请重新下载安装镜像。"
            return
        }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(current, kTISPropertyBundleID),
           Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == InstallPayload.identifier {
            error = "请先切换到其他输入法，再安装或升级 WA 五笔。"
            return
        }
        installing = true
        error = nil
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: InstallPayload.identifier) {
            _ = app.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try InstallPayload.install(archive: archive, in: InstallPayload.folder) }
            DispatchQueue.main.async {
                self.installing = false
                switch result {
                case .success(let destination):
                    _ = TISRegisterInputSource(destination as CFURL)
                    self.installed = true
                case .failure:
                    self.error = "安装失败，请检查当前用户的「Input Methods」目录，或重新下载安装镜像。"
                }
            }
        }
    }
}

private struct InstallerView: View {
    @ObservedObject var model: InstallWindow
    private let green = Color(red: 0.23, green: 0.51, blue: 0.41)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let logo = NSImage(named: "BrandIcon") {
                Image(nsImage: logo).resizable().frame(width: 61, height: 61)
                    .accessibilityHidden(true)
            }
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
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("取消") { NSApp.terminate(nil) }.disabled(model.installing)
                    Spacer()
                    if model.installing { ProgressView().controlSize(.small) }
                    Button("安装") { model.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.installing)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(29)
        .frame(width: 435, alignment: .leading)
        .tint(green)
    }
}
