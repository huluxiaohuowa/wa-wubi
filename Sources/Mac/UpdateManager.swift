import AppKit
import CryptoKit
import Security
import SwiftUI
import WubiCore

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private var automatic: Bool { LibraryStore.shared.preferences.autoCheckUpdates ?? true }
    private var automaticallyInstalls: Bool { LibraryStore.shared.preferences.automaticallyInstallUpdates ?? false }
    @Published private(set) var available: WubiUpdate?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()
    private var schedule: Timer?

    func start() {
        guard schedule == nil else { return }
        schedule = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Self.shared.checkWhenDue() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            checkWhenDue()
        }
    }

    private func checkWhenDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if automatic && Date().timeIntervalSince(last) >= 86_400 { check(installIfAvailable: automaticallyInstalls) }
    }

    func check() { check(installIfAvailable: automaticallyInstalls) }

    private func check(installIfAvailable: Bool) {
        guard !busy else { return }
        busy = true
        message = "正在检查更新…"
        Task {
            var checked = false
            defer {
                busy = false
                if installIfAvailable, automaticallyInstalls, available != nil, checked { installUpdate() }
            }
            do {
                available = try await UpdateTransport.first(for: UpdateCatalog.api) { url in
                    let data = try await fetch(url, max: 768 * 1024, api: true)
                    return try UpdateCatalog.newest(in: data, newerThan: Self.current)
                }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                checked = true
                if let available { message = "可以更新到 \(available.version)。" }
                else { message = "已是最新版本。" }
            } catch {
                message = "各更新源暂时无法连接或返回了无效数据。"
            }
        }
    }

    func installUpdate() {
        guard let available, !busy else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "top.fuluwa.WAWubiInstaller").isEmpty else {
            message = "安装窗口已打开。"
            return
        }
        busy = true
        message = "正在下载并校验更新…"
        Task {
            defer { busy = false }
            var downloaded = false
            do {
                let bytes = try await UpdateTransport.first(for: available.url) { url in
                    let data = try await fetch(url, max: available.bytes, api: false)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard data.count == available.bytes, digest == available.sha256 else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    return data
                }
                downloaded = true
                let installer = try await Task.detached(priority: .utility) {
                    try Self.prepareInstaller(dmg: bytes, version: available.version)
                }.value
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--apply-update"]
                configuration.createsNewApplicationInstance = true
                let result = try await NSWorkspace.shared.openApplication(at: installer, configuration: configuration)
                if !result.isTerminated {
                    message = "正在安装更新。若 macOS 请求管理员授权，请批准。"
                }
            } catch {
                message = downloaded ? "安装器签名校验或解包失败。" : "各更新源下载失败，请稍后重试。"
            }
        }
    }

    nonisolated private func fetch(_ url: URL, max size: Int, api: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        if api {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("WA Wubi Update", forHTTPHeaderField: "User-Agent")
        }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.expectedContentLength <= size else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < size else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    nonisolated private static func prepareInstaller(dmg: Data, version: String) throws -> URL {
        let files = FileManager.default
        let folder = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("top.fuluwa.inputmethod.Wubi86/updates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let point = folder.appendingPathComponent("mount", isDirectory: true)
        let image = folder.appendingPathComponent("WA-Wubi.dmg")
        try files.createDirectory(at: point, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? files.removeItem(at: folder) } }
        try dmg.write(to: image, options: .atomic)
        let team = try signingTeam()
        try verifySignature(at: image, identifier: "top.fuluwa.WAWubiInstaller.Image", team: team)
        try hdiutil(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", point.path, image.path])
        defer { try? hdiutil(["detach", point.path]) }

        let installer = point.appendingPathComponent("安装 WA 五笔.app", isDirectory: true)
        guard Bundle(url: installer)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try verifySignature(at: installer, identifier: "top.fuluwa.WAWubiInstaller", team: team)
        let copy = folder.appendingPathComponent("安装 WA 五笔.app", isDirectory: true)
        try files.copyItem(at: installer, to: copy)
        try verifySignature(at: copy, identifier: "top.fuluwa.WAWubiInstaller", team: team)
        try? files.removeItem(at: image)
        complete = true
        return copy
    }

    nonisolated private static func signingTeam() throws -> String {
        var running: SecStaticCode?
        var signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &running) == errSecSuccess,
              let running, SecCodeCopySigningInformation(running, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let fields = signing as? [String: Any], let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return team
    }

    nonisolated private static func verifySignature(at url: URL, identifier: String, team: String) throws {
        var candidate: SecStaticCode?
        var requirement: SecRequirement?
        let identity = """
            identifier "\(identifier)" and anchor apple generic and notarized and
            certificate leaf[subject.OU] = "\(team)" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
            """
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    nonisolated private static func hdiutil(_ arguments: [String]) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        tool.arguments = arguments
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

struct UpdateSettings: View {
    @ObservedObject var manager: UpdateManager
    @ObservedObject private var store = LibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("已安装 \(UpdateManager.current)").foregroundStyle(.secondary)
            Toggle("自动检查更新", isOn: Binding(
                get: { store.preferences.autoCheckUpdates ?? true },
                set: { value in store.update { $0.autoCheckUpdates = value } }
            ))
            Toggle("自动下载并安装", isOn: Binding(
                get: { store.preferences.automaticallyInstallUpdates ?? false },
                set: { value in store.update { $0.automaticallyInstallUpdates = value } }
            ))
            .disabled(store.preferences.autoCheckUpdates == false)
            HStack {
                Button("检查更新", action: manager.check).disabled(manager.busy)
                if manager.available != nil {
                    Button("立即更新", action: manager.installUpdate).disabled(manager.busy)
                }
                if manager.busy { ProgressView().controlSize(.small) }
            }
            if !manager.message.isEmpty { Text(manager.message).foregroundStyle(.secondary) }
        }
    }
}
