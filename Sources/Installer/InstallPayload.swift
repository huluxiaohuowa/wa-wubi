import Foundation
import Security

enum InstallPayload {
    static let name = "WA 五笔.app"
    static let identifier = "top.fuluwa.inputmethod.Wubi86"
    static let mode = identifier + ".Hans"
    static let folder = URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true)
    static let legacyFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)

    static func install(archive: URL) throws -> URL {
        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("WA-Wubi-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }

        try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        let source = staging.appendingPathComponent(name, isDirectory: true)
        let team = try signingTeam()
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Bundle(url: source)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let requirement = """
        identifier "\(identifier)" and anchor apple generic and notarized and
        certificate leaf[subject.OU] = "\(team)" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
        let command = (["/usr/bin/env", "-i", "/bin/bash", "-c", systemInstall, "wa-wubi", source.path, version, requirement]
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }).joined(separator: " ")
        try run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run", "--", command,
        ])
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    static func archiveLegacyInstall() throws {
        let files = FileManager.default
        let legacy = legacyFolder.appendingPathComponent(name, isDirectory: true)
        guard Bundle(url: legacy)?.bundleIdentifier == identifier else { return }
        let backups = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WA 五笔/安装备份")
        try files.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("WA 五笔-" + UUID().uuidString + ".backup", isDirectory: true)
        try files.moveItem(at: legacy, to: backup)
    }

    private static func run(_ program: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func signingTeam() throws -> String {
        var signed: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &signed) == errSecSuccess,
              let signed, SecCodeCopySigningInformation(signed, SecCSFlags(rawValue: kSecCSSigningInformation),
                                                       &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return team
    }

    // Copy to a root-owned directory before verifying or acting on the payload.
    private static let systemInstall = #"""
        set -euo pipefail
        umask 077
        folder='/Library/Input Methods'
        target="$folder/WA 五笔.app"
        stage="$(/usr/bin/mktemp -d "$folder/.wa-wubi.XXXXXXXX")"
        payload="$stage/WA 五笔.app"
        backup="$stage/previous.app"

        cleanup() {
            if [[ -e "$backup" && ! -e "$target" ]]; then
                /bin/mv "$backup" "$target" || return
            fi
            /bin/rm -rf "$stage"
        }
        trap cleanup EXIT

        [[ -d "$1" && ! -L "$1" && ! -L "$target" ]] || exit 1
        /usr/bin/ditto "$1" "$payload" || exit 1
        /usr/bin/codesign --verify --strict --deep --all-architectures -R "=$3" "$payload" || exit 1
        version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$payload/Contents/Info.plist")"
        [[ "$version" == "$2" ]] || exit 1
        /usr/sbin/chown -R -P root:wheel "$payload"
        /bin/chmod -R a+rX,go-w "$payload"

        if [[ -e "$target" ]]; then
            bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")"
            [[ "$bundle" == top.fuluwa.inputmethod.Wubi86 ]] || exit 1
            /bin/mv "$target" "$backup"
        fi
        /bin/mv "$payload" "$target" || exit 1

        # Register the installed, verified bundle through the privileged install context.
        "$target/Contents/MacOS/WAWubi" --register-input-source || true
        """#
}
