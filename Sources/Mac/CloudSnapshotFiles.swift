import Foundation
import WubiCore

enum CloudSnapshotFiles {
    enum AccessError: Error {
        case downloading
        case invalidSnapshot
    }

    static func read(from folder: URL, excluding device: String? = nil) throws -> Snapshot? {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .fileSizeKey, .isRegularFileKey]
        let items: [URL]
        do {
            items = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        var merged = Snapshot()
        var found = false
        var downloading = false
        for item in items {
            let legacyPlaceholder = item.pathExtension == "icloud"
            let file = legacyPlaceholder ? item.deletingPathExtension() : item
            guard file.pathExtension == "json" else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let id = legacyPlaceholder && name.hasPrefix(".") ? String(name.dropFirst()) : name
            guard UUID(uuidString: id) != nil, id != device else { continue }
            let values = try item.resourceValues(forKeys: Set(keys))
            if legacyPlaceholder || values.ubiquitousItemDownloadingStatus == .notDownloaded {
                let target = legacyPlaceholder ? folder.appendingPathComponent(id + ".json") : item
                try files.startDownloadingUbiquitousItem(at: target)
                downloading = true
                continue
            }
            let sizeLimit = 128 * 1024 * 1024
            guard values.isRegularFile == true, let size = values.fileSize, size <= sizeLimit else {
                throw AccessError.invalidSnapshot
            }
            var coordinationError: NSError?
            var read: Result<Snapshot, Error>?
            NSFileCoordinator().coordinate(readingItemAt: item, options: [], error: &coordinationError) { url in
                read = Result {
                    let data = try Data(contentsOf: url)
                    guard data.count <= sizeLimit else { throw AccessError.invalidSnapshot }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                    guard snapshot.version == Snapshot.format else { throw AccessError.invalidSnapshot }
                    return snapshot
                }
            }
            if let coordinationError { throw coordinationError }
            guard let read else { throw AccessError.invalidSnapshot }
            merged.merge(try read.get())
            found = true
        }
        if downloading { throw AccessError.downloading }
        return found ? merged : nil
    }

    static func write(_ snapshot: Snapshot, in folder: URL, device: String) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(device + ".json")
        var coordinationError: NSError?
        var writing: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { file in
            writing = Result { try data.write(to: file, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        guard let writing else { throw CocoaError(.fileWriteUnknown) }
        try writing.get()
    }
}
