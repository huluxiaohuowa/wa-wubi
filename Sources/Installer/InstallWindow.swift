import AppKit
import Carbon
import SwiftUI

final class InstallWindow: ObservableObject {
    static let shared = InstallWindow()
    private var window: NSWindow?
    @Published private(set) var installed = false
    @Published private(set) var installing = false
    @Published private(set) var error: String?
    @Published private(set) var sourceEnabled = false
    @Published private(set) var registrationMessage: String?

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
            let result = Result { try InstallPayload.install(archive: archive) }
            DispatchQueue.main.async {
                self.installing = false
                switch result {
                case .success(let destination):
                    self.installed = true
                    do {
                        try InstallPayload.archiveLegacyInstall()
                        self.enableSource(at: destination)
                    } catch {
                        self.registrationMessage = "系统版本已安装。请先移走个人输入法目录中残留的 WA 五笔旧版，再启用输入源。"
                    }
                case .failure:
                    self.error = "未完成系统安装。请确认已批准管理员授权，或重新下载安装镜像。"
                }
            }
        }
    }
    func enableSource(at destination: URL = InstallPayload.folder.appendingPathComponent(InstallPayload.name)) {
        guard TISRegisterInputSource(destination as CFURL) == noErr else {
            registrationMessage = "macOS 尚未注册 WA 五笔。请重新打开键盘设置，或在下次登录后添加。"
            return
        }
        findAndEnable(remainingAttempts: 8)
    }

    private func findAndEnable(remainingAttempts: Int) {
        let query = [kTISPropertyInputSourceID as String: InstallPayload.mode] as CFDictionary
        let modes = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        if let mode = modes?.first, TISEnableInputSource(mode) == noErr {
            sourceEnabled = Self.isAvailableInMenu()
            if sourceEnabled {
                registrationMessage = "可在菜单栏的输入菜单切换到 WA 五笔。"
                return
            }
        }
        if remainingAttempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.findAndEnable(remainingAttempts: remainingAttempts - 1)
            }
        } else {
            registrationMessage = "系统已安装，但当前账号的输入菜单尚未刷新。请重新打开键盘设置添加 WA 五笔，或在下次登录后添加。"
        }
    }

    private static func isAvailableInMenu() -> Bool {
        // The mode can report itself as enabled before the account's input menu persists it.
        guard let sources = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleEnabledInputSources"]
            as? [[String: Any]] else { return false }
        return sources.contains {
            $0["Bundle ID"] as? String == InstallPayload.identifier &&
                ($0["Input Mode"] as? String == InstallPayload.mode ||
                 $0["InputSourceKind"] as? String == "Keyboard Input Method Without Modes")
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
                Text("已安装到系统输入法目录。这台 Mac 的每个账号都可以在自己的输入源设置中启用 WA 五笔。")
                    .foregroundStyle(.secondary)
                if let message = model.registrationMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                HStack {
                    Button("完成") { NSApp.terminate(nil) }
                    Spacer()
                    if !model.sourceEnabled {
                        Button("重新启用") { model.enableSource() }
                    }
                    Button("打开键盘设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("将原生 86 五笔输入法安装到系统目录，供这台 Mac 的所有账号使用。安装需要管理员授权。")
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
