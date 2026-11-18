import Foundation
import WubiCore

enum CloudSnapshotFiles {
    enum AccessError: Error {
        case downloading
        case invalidSnapshot
    }

    private static let filename = "state.json"
    private static let sizeLimit = 128 * 1024 * 1024

    static func read(from folder: URL) throws -> Snapshot? {
        let imported = try readDeviceSnapshots(from: folder)
        return try coordinate(folder.appendingPathComponent(filename)) { file in
            let (snapshot, conflicts) = try readSharedFile(file)
            guard snapshot != nil || imported != nil || !conflicts.isEmpty else { return nil }
            var merged = snapshot ?? Snapshot()
            if let imported { merged.merge(imported) }
            for version in conflicts { merged.merge(try decode(version.url)) }
            return merged
        }
    }

    static func sync(_ local: Snapshot, in folder: URL, canWrite: () -> Bool) throws -> Snapshot {
        let imported = try readDeviceSnapshots(from: folder)
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try coordinate(folder.appendingPathComponent(filename), writing: true) { file in
            let (current, conflicts) = try readSharedFile(file)
            var merged = current ?? Snapshot()
            var needsWrite = current == nil
            if let imported, merged.merge(imported) { needsWrite = true }
            for version in conflicts {
                if merged.merge(try decode(version.url)) { needsWrite = true }
            }
            if merged.merge(local) { needsWrite = true }

            guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
            if needsWrite {
                let data = try JSONEncoder().encode(merged)
                guard data.count <= sizeLimit else { throw AccessError.invalidSnapshot }
                try data.write(to: file, options: .atomic)
            }
            for version in conflicts {
                version.isResolved = true
                try version.remove()
            }
            return merged
        }
    }

    private static func readSharedFile(_ file: URL) throws -> (Snapshot?, [NSFileVersion]) {
        let current: Snapshot?
        do {
            current = try decode(file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            current = nil
        }
        return (current, NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? [])
    }

    private static func readDeviceSnapshots(from folder: URL) throws -> Snapshot? {
        let files = FileManager.default
        let items: [URL]
        do {
            items = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }

        var merged: Snapshot?
        for item in items {
            let placeholder = item.pathExtension == "icloud"
            let name = item.lastPathComponent
            let file = placeholder && name.hasPrefix(".") ? String(name.dropFirst().dropLast(".icloud".count)) : name
            let id = String(file.dropLast(".json".count))
            let isDeviceSnapshot = file.hasSuffix(".json") && UUID(uuidString: id) != nil
            guard file == filename || isDeviceSnapshot else { continue }
            if placeholder {
                try files.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(file))
                throw AccessError.downloading
            }
            guard isDeviceSnapshot else { continue }
            let snapshot = try coordinate(item) { try decode($0) }
            if merged == nil { merged = snapshot }
            else { merged?.merge(snapshot) }
        }
        return merged
    }

    private static func decode(_ url: URL) throws -> Snapshot {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey, .isRegularFileKey])
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw AccessError.downloading
        }
        guard values.isRegularFile == true, let size = values.fileSize, size <= sizeLimit else {
            throw AccessError.invalidSnapshot
        }
        let data = try Data(contentsOf: url)
        guard data.count <= sizeLimit,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Snapshot.format else { throw AccessError.invalidSnapshot }
        return snapshot
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
