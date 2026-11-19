import AppKit
import Carbon

enum Uninstall {
    private static let identifier = "top.fuluwa.inputmethod.Wubi86"
    private static let name = "WA 五笔.app"
    private static let system = URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    private static let user = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)

    @MainActor
    static func perform() async throws {
        let systemInstalled = isInstalled(at: system)
        let userInstalled = isInstalled(at: user)
        guard systemInstalled || userInstalled else { throw Failure.missing }

        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let selectedWA = current.map { [identifier, identifier + ".Hans"].contains(inputID($0)) } ?? false
        if selectedWA {
            guard let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  ![identifier, identifier + ".Hans"].contains(inputID(fallback)),
                  TISSelectInputSource(fallback) == noErr else { throw Failure.inputSource }
        }

        var disabled: [TISInputSource] = []
        do {
            for id in [identifier + ".Hans", identifier] {
                let query = [kTISPropertyInputSourceID as String: id] as CFDictionary
                let enabled = TISCreateInputSourceList(query, false)?.takeRetainedValue() as? [TISInputSource] ?? []
                for source in enabled {
                    guard TISDisableInputSource(source) == noErr else { throw Failure.inputSource }
                    disabled.append(source)
                }
            }
            if systemInstalled { try await Task.detached { try removeSystemBundle() }.value }
            if userInstalled { try FileManager.default.trashItem(at: user, resultingItemURL: nil) }
        } catch {
            if isInstalled(at: system) || isInstalled(at: user) {
                for source in disabled { _ = TISEnableInputSource(source) }
                if selectedWA, let current { _ = TISSelectInputSource(current) }
            }
            throw error
        }
    }

    private static func isInstalled(at url: URL) -> Bool {
        guard let properties = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              properties.isDirectory == true, properties.isSymbolicLink == false else { return false }
        return Bundle(url: url)?.bundleIdentifier == identifier
    }

    private static func inputID(_ source: TISInputSource) -> String {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func removeSystemBundle() throws {
        if (try? FileManager.default.trashItem(at: system, resultingItemURL: nil)) != nil { return }
        let command = """
        set -e
        target='/Library/Input Methods/WA 五笔.app'
        [ -d "$target" ] && [ ! -L "$target" ] && [ ! -L '/Library/Input Methods' ] || exit 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")" = 'top.fuluwa.inputmethod.Wubi86' ]
        /bin/rm -rf -- "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run", "--", command,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !FileManager.default.fileExists(atPath: system.path) else {
            throw Failure.authorization
        }
    }

    private enum Failure: LocalizedError {
        case missing, inputSource, authorization

        var errorDescription: String? {
            switch self {
            case .missing: return "没有找到已安装的 WA 五笔。"
            case .inputSource: return "macOS 无法停用 WA 五笔。请先切换到系统自带的输入源。"
            case .authorization: return "系统级安装未能移除。需要在 macOS 提示中完成管理员授权。"
            }
        }
    }
}
