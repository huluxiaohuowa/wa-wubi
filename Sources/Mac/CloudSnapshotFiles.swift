import Foundation
import WubiCore

enum CloudSnapshotFiles {
    enum AccessError: Error {
        case downloading
        case invalidSnapshot
    }

    private static let sizeLimit = 128 * 1024 * 1024

    private enum Part: Hashable {
        case settings, personal, dictionary(String)

        var filename: String {
            switch self {
            case .settings: return "state.json"
            case .personal: return "personal.json"
            case .dictionary(let id): return id + ".json"
            }
        }

        var groupKey: String? {
            if case .dictionary(let id) = self { return "group/" + id }
            return nil
        }

        func url(in folder: URL) -> URL {
            let parent = self == .settings ? folder : folder.appendingPathComponent("dictionaries", isDirectory: true)
            return parent.appendingPathComponent(filename)
        }
    }

    private struct DictionaryRecord<Value: Codable>: Codable {
        let revision: Revision
        let modifiedAt: Date?
        let value: Value?

        init(_ change: Change) throws {
            revision = change.revision
            modifiedAt = change.modifiedAt
            value = try change.value.map { try JSONDecoder().decode(Value.self, from: $0) }
        }

        func change() throws -> Change {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return Change(revision: revision, value: try value.map { try encoder.encode($0) }, modifiedAt: modifiedAt)
        }
    }

    private struct PersonalFile: Codable {
        let entries: [String: DictionaryRecord<Entry>]
    }

    private struct FileState {
        let current: Snapshot?
        let conflicts: [NSFileVersion]
        let merged: Snapshot
    }

    static func read(from folder: URL) throws -> Snapshot? {
        try coordinate(Part.settings.url(in: folder)) { file in
            let settings = try readFile(file, as: .settings)
            var snapshot = settings.merged
            let legacy = try readLegacy(in: folder)
            snapshot.merge(legacy)
            let parts = try dictionaryParts(in: folder)
            for part in parts {
                let dictionary = try coordinate(part.url(in: folder)) { try readFile($0, as: part) }
                snapshot.merge(dictionary.merged)
            }
            return settings.current != nil || !snapshot.values.isEmpty || !parts.isEmpty ? snapshot : nil
        }
    }

    static func sync(_ local: Snapshot, in folder: URL, canWrite: () -> Bool) throws -> Snapshot {
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Hold a coordinated access to the settings file through the split so a second local
        // process cannot read or change the layout while its files are being updated.
        return try coordinate(Part.settings.url(in: folder), writing: true) { file in
            let settings = try readFile(file, as: .settings)
            var incoming = settings.merged
            incoming.merge(try readLegacy(in: folder))
            incoming.merge(local)
            var parts = try split(incoming)
            let settingsPart = parts.removeValue(forKey: .settings) ?? Snapshot()
            let dictionaries = try dictionaryParts(in: folder).union(parts.keys)
            if !dictionaries.isEmpty {
                let directory = Part.personal.url(in: folder).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var result = settingsPart
            var removed: [Part: Snapshot] = [:]
            for part in dictionaries {
                let desired = parts[part] ?? Snapshot()
                let synced = try coordinate(part.url(in: folder), writing: true) { url in
                    let onDisk = try readFile(url, as: part)
                    var combined = onDisk.merged
                    combined.merge(desired)
                    if let key = part.groupKey, let change = combined.values[key], change.value == nil {
                        if onDisk.current != nil || !onDisk.conflicts.isEmpty { removed[part] = combined }
                        return combined
                    }
                    try commit(combined, replacing: onDisk, at: url, as: part, canWrite: canWrite)
                    return combined
                }
                result.merge(synced)
            }

            // A deletion is recorded durably before removing its dictionary file so a stale
            // Mac cannot recreate the file with an older copy.
            var updatedSettings = settingsPart
            let previousDeletions = settings.merged.values.filter { key, change in
                key.hasPrefix("group/") && change.value == nil
            }
            updatedSettings.merge(Snapshot(values: previousDeletions))
            for part in parts.keys {
                guard let key = part.groupKey, let change = result.values[key], change.value == nil else { continue }
                updatedSettings.merge(Snapshot(values: [key: change]))
            }
            try commit(updatedSettings, replacing: settings, at: file, as: .settings, canWrite: canWrite)
            for (part, deletion) in removed {
                try coordinate(part.url(in: folder), writing: true) { url in
                    let onDisk = try readFile(url, as: part)
                    var latest = deletion
                    latest.merge(onDisk.merged)
                    guard let key = part.groupKey, latest.values[key]?.value == nil else {
                        result.merge(latest)
                        return
                    }
                    guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
                    if onDisk.current != nil { try FileManager.default.removeItem(at: url) }
                    try resolve(onDisk.conflicts)
                }
            }
            result.merge(updatedSettings)
            return result
        }
    }

    private static func split(_ snapshot: Snapshot) throws -> [Part: Snapshot] {
        var values: [Part: [String: Change]] = [:]
        for (key, change) in snapshot.values {
            let part: Part
            if key.hasPrefix("personal/") {
                part = .personal
            } else if key.hasPrefix("group/") {
                let id = String(key.dropFirst("group/".count))
                guard validID(id) else { throw AccessError.invalidSnapshot }
                part = .dictionary(id)
            } else {
                part = .settings
            }
            values[part, default: [:]][key] = change
        }
        return values.mapValues { Snapshot(values: $0) }
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && id != "personal"
    }

    private static func dictionaryParts(in folder: URL) throws -> Set<Part> {
        let directory = Part.personal.url(in: folder).deletingLastPathComponent()
        let files = try listJSON(in: directory) { stem in stem == "personal" || validID(stem) }
        return Set(files.map {
            let stem = $0.deletingPathExtension().lastPathComponent
            return stem == "personal" ? .personal : .dictionary(stem)
        })
    }

    private static func readLegacy(in folder: URL) throws -> Snapshot {
        var merged = Snapshot()
        for file in try listJSON(in: folder, include: { $0 == "state" || UUID(uuidString: $0) != nil }) {
            guard file.lastPathComponent != Part.settings.filename else { continue }
            let snapshot = try coordinate(file) { try readFile($0, as: .settings).merged }
            merged.merge(snapshot)
        }
        return merged
    }

    private static func listJSON(in folder: URL, include: (String) -> Bool) throws -> [URL] {
        let files = FileManager.default
        let items: [URL]
        do {
            items = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where missing(error) {
            return []
        }
        var available: [URL] = []
        for item in items {
            let placeholder = item.pathExtension == "icloud"
            let file = placeholder ? item.deletingPathExtension() : item
            guard file.pathExtension == "json" else { continue }
            let stem = file.deletingPathExtension().lastPathComponent
            let name = placeholder && stem.hasPrefix(".") ? String(stem.dropFirst()) : stem
            guard include(name) else { continue }
            if placeholder {
                try files.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name + ".json"))
                throw AccessError.downloading
            }
            available.append(file)
        }
        return available
    }

    private static func readFile(_ file: URL, as part: Part) throws -> FileState {
        let current: Snapshot?
        do {
            current = try decode(file, as: part)
        } catch let error as CocoaError where missing(error) {
            current = nil
        }
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
        var merged = current ?? Snapshot()
        for version in conflicts { merged.merge(try decode(version.url, as: part)) }
        return FileState(current: current, conflicts: conflicts, merged: merged)
    }

    private static func decode(_ url: URL, as part: Part) throws -> Snapshot {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey, .isRegularFileKey])
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw AccessError.downloading
        }
        guard values.isRegularFile == true, let size = values.fileSize, size <= sizeLimit else {
            throw AccessError.invalidSnapshot
        }
        let data = try Data(contentsOf: url)
        guard data.count <= sizeLimit else { throw AccessError.invalidSnapshot }

        let decoder = JSONDecoder()
        do {
            switch part {
            case .settings:
                let snapshot = try decoder.decode(Snapshot.self, from: data)
                guard snapshot.version == Snapshot.format else { throw AccessError.invalidSnapshot }
                return snapshot
            case .personal:
                let file = try decoder.decode(PersonalFile.self, from: data)
                guard file.entries.keys.allSatisfy({ $0.hasPrefix("personal/") }) else {
                    throw AccessError.invalidSnapshot
                }
                return Snapshot(values: try file.entries.mapValues { try $0.change() })
            case .dictionary(let id):
                let record = try decoder.decode(DictionaryRecord<WordGroup>.self, from: data)
                guard record.value?.id == id else { throw AccessError.invalidSnapshot }
                return Snapshot(values: ["group/" + id: try record.change()])
            }
        } catch {
            throw AccessError.invalidSnapshot
        }
    }

    private static func commit(
        _ snapshot: Snapshot, replacing stored: FileState, at url: URL, as part: Part, canWrite: () -> Bool
    ) throws {
        guard stored.current?.values != snapshot.values || !stored.conflicts.isEmpty else { return }
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        if stored.current?.values != snapshot.values {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data: Data
            switch part {
            case .settings:
                data = try encoder.encode(snapshot)
            case .personal:
                let records = try snapshot.values.mapValues { try DictionaryRecord<Entry>($0) }
                data = try encoder.encode(PersonalFile(entries: records))
            case .dictionary(let id):
                guard let change = snapshot.values["group/" + id] else { return }
                data = try encoder.encode(DictionaryRecord<WordGroup>(change))
            }
            guard data.count <= sizeLimit else { throw AccessError.invalidSnapshot }
            try data.write(to: url, options: .atomic)
        }
        try resolve(stored.conflicts)
    }

    private static func resolve(_ conflicts: [NSFileVersion]) throws {
        for version in conflicts {
            version.isResolved = true
            try version.remove()
        }
    }

    private static func missing(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private static func coordinate<T>(
        _ url: URL, writing: Bool = false, _ access: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { file in
                result = Result { try access(file) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { file in
                result = Result { try access(file) }
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(writing ? .fileWriteUnknown : .fileReadUnknown) }
        return try result.get()
    }
}
