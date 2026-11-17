import Foundation
import Security

enum InstallPayload {
    static let name = "WA 五笔.app"
    static let identifier = "top.fuluwa.inputmethod.Wubi86"
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)

    static func install(archive: URL, in folder: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".wawubi-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationReason == .exit, unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        let source = staging.appendingPathComponent(name, isDirectory: true)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard Bundle(url: source)?.bundleIdentifier == identifier,
              SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"\(identifier)\" and anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let destination = folder.appendingPathComponent(name, isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try files.moveItem(at: source, to: destination)
        }
        return destination
    }
}
