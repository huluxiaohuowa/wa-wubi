import CryptoKit
import Darwin
import Foundation
import SwiftUI
import WubiCore


enum MobileStorage {
    struct FileStamp: Equatable {
        let inode: UInt64
        let modified: Date
        let size: UInt64
    }

    static let group = "group.top.fuluwa.inputmethod.Wubi86"
    static let cloud = "iCloud.top.fuluwa.inputmethod.Wubi86"
    static var shared: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var local: URL {
        (shared ?? URL.applicationSupportDirectory).appendingPathComponent("mobile-state.json")
    }
    static var backup: URL { local.deletingLastPathComponent().appendingPathComponent("before-cloud.json") }

    static func stamp(at url: URL = local) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return FileStamp(inode: inode.uint64Value, modified: modified, size: size.uint64Value)
    }

    static func read() throws -> Snapshot {
        do {
            let data = try Data(contentsOf: local, options: .mappedIfSafe)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == Snapshot.format else { throw CocoaError(.fileReadCorruptFile) }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot()
        }
    }

    static func update(_ edit: (inout Snapshot) throws -> Void) throws -> Snapshot {
        try update(reusing: nil, edit).snapshot
    }

    static func update(reusing cached: (Snapshot, FileStamp)?,
                       _ edit: (inout Snapshot) throws -> Void) throws
        -> (snapshot: Snapshot, stamp: FileStamp?, reused: Bool) {
        let file = local
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var result: Result<(Snapshot, FileStamp?, Bool), Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            result = autoreleasepool {
                Result {
                    let reused = cached.map { $0.1 == stamp(at: url) } ?? false
                    var state = try (reused ? cached?.0 : nil) ?? read()
                    let before = state.values
                    try edit(&state)
                    if state.values != before || !FileManager.default.fileExists(atPath: url.path) {
                        try write(state, to: url)
                    }
                    return (state, stamp(at: url), reused)
                }
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private static func write(_ state: Snapshot, to url: URL) throws {
        let estimatedBytes = state.values.values.reduce(0) { $0 + ($1.value?.count ?? 0) }
        guard estimatedBytes >= 1024 * 1024 else {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            return
        }

        // Keep the on-disk JSON format and atomic replacement, while encoding large dictionaries one at a time.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".snapshot-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        var buffer = Data("{\"version\":\(state.version),\"values\":{".utf8)
        var separator = false
        for (key, change) in state.values {
            try autoreleasepool {
                if separator { buffer.append(44) }
                separator = true
                buffer.append(try encoder.encode(key))
                buffer.append(58)
                buffer.append(try encoder.encode(change))
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        buffer.append(contentsOf: [125, 125])
        try handle.write(contentsOf: buffer)
        try handle.close()
        try temporary.withUnsafeFileSystemRepresentation { source in
            try url.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { throw CocoaError(.fileWriteInvalidFileName) }
                guard rename(source, target) == 0 else {
                    throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}

@MainActor final class MobileStore: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var libraries: [WordGroup] = []
    @Published private(set) var status = ""
    @Published private(set) var ready = false
    @Published private(set) var lookupRevision = 0
    @Published private(set) var syncing = false
    @Published var touchCorrection = false {
        didSet { defaults.set(touchCorrection, forKey: "touchCorrection") }
    }
    @Published var slideCorrection = true {
        didSet { defaults.set(slideCorrection, forKey: "slideCorrection") }
    }
    @Published var splitWideKeyboard = true {
        didSet { defaults.set(splitWideKeyboard, forKey: "splitWideKeyboard") }
    }
    @Published var keySound = false {
        didSet { defaults.set(keySound, forKey: "keySound") }
    }
    @Published var keyHaptics = false {
        didSet { defaults.set(keyHaptics, forKey: "keyHaptics") }
    }
    @Published var syncEnabled = false {
        didSet { defaults.set(syncEnabled, forKey: "mobileSyncEnabled") }
    }

    private let defaults = UserDefaults(suiteName: MobileStorage.group) ?? .standard
    private let device = UUID().uuidString
    private var snapshot = Snapshot()
    private var snapshotGeneration = 0
    private var snapshotStamp: MobileStorage.FileStamp?
    private var reloadingForKeyboard = false
    private var refreshingLibraryIndex = false
    private var keyboardReloadPending = false
    private var pendingLearned: [Entry] = []
    private var savingLearned = false
    private var personalEntries: [Entry] = []
    private let keepsLibraryLists: Bool
    private(set) var lexicon = Lexicon([])
    private(set) var preferredCodes: [String: String] = [:]
    private var extra: [String: [Entry]] = [:]
    private var importedIndex: MobileLibraryIndex?
    private var edits: [String: [String: WordEdit]] = [:]
    private var orders: [String: [Candidate]] = [:]
    private var ranking: [String: [String: Int]] = [:]
    var hasCloudBackup: Bool { FileManager.default.fileExists(atPath: MobileStorage.backup.path) }

    init(loadSnapshotImmediately: Bool = true, keepsLibraryLists: Bool = true) {
        self.keepsLibraryLists = keepsLibraryLists
        // The app's practice screen and the extension use the same bundled file.
        let embedded = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("WAWubiKeyboard.appex/wubi86.sqlite")
        if let url = Bundle.main.url(forResource: "wubi86", withExtension: "sqlite") ?? embedded,
           let compiled = Lexicon(compiledAt: url) {
            lexicon = compiled
            ready = true
        }
        if loadSnapshotImmediately { reload() }
    }

    func reload() {
        reloadLocalOptions()
        let stamp = MobileStorage.stamp()
        if let stamp, stamp == snapshotStamp { return }
        if let saved = try? MobileStorage.read() {
            apply(saved)
            snapshotStamp = stamp
        }
    }

    func prepareForKeyboard() async {
        if savingLearned {
            keyboardReloadPending = true
            return
        }
        guard !reloadingForKeyboard else { return }
        reloadingForKeyboard = true
        defer {
            reloadingForKeyboard = false
            startSavingLearnedPhrases()
        }
        reloadLocalOptions()
        await reloadKeyboardSnapshot()
    }

    private func reloadKeyboardSnapshot() async {
        let stamp = MobileStorage.stamp()
        if let stamp, stamp == snapshotStamp { return }
        let generation = snapshotGeneration
        let saved = await Task.detached(priority: .userInitiated) {
            autoreleasepool { try? MobileStorage.read() }
        }.value
        guard !Task.isCancelled, generation == snapshotGeneration, let saved else { return }
        guard saved.values != snapshot.values else {
            snapshotStamp = stamp
            return
        }
        let keepsLibraryLists = keepsLibraryLists
        let indexesLibraries = MobileSnapshotIndex.libraryRecordsChanged(from: snapshot, to: saved)
        // The live lookup index stays usable while rebuilding. Drop the previous encoded copy now.
        snapshot = saved
        snapshotStamp = nil
        refreshingLibraryIndex = indexesLibraries
        let index = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                MobileSnapshotIndex(saved, keepsLibraryLists: keepsLibraryLists, indexesLibraries: indexesLibraries)
            }
        }.value
        if generation == snapshotGeneration {
            apply(saved, index: index)
            snapshotStamp = stamp
        }
    }

    private func reloadLocalOptions() {
        let touchCorrection = defaults.bool(forKey: "touchCorrection")
        let slideCorrection = defaults.object(forKey: "slideCorrection") as? Bool ?? true
        let splitWideKeyboard = defaults.object(forKey: "splitWideKeyboard") as? Bool ?? true
        let keySound = defaults.bool(forKey: "keySound")
        let keyHaptics = defaults.bool(forKey: "keyHaptics")
        let syncEnabled = defaults.bool(forKey: "mobileSyncEnabled")
        if self.touchCorrection != touchCorrection { self.touchCorrection = touchCorrection }
        if self.slideCorrection != slideCorrection { self.slideCorrection = slideCorrection }
        if self.splitWideKeyboard != splitWideKeyboard { self.splitWideKeyboard = splitWideKeyboard }
        if self.keySound != keySound { self.keySound = keySound }
        if self.keyHaptics != keyHaptics { self.keyHaptics = keyHaptics }
        if self.syncEnabled != syncEnabled { self.syncEnabled = syncEnabled }
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        let previous = preferences
        var next = previous
        change(&next)
        guard next != previous else { return }
        edit { try $0.updatePreferences(from: previous, to: next, device: device) }
    }

    func candidates(_ mode: Composition.Mode, _ code: String) -> [Candidate] {
        if mode == .pinyin { return lexicon.compiledPinyinCandidates(for: code) }
        if code == "zz", preferences.zFunction {
            return "※ — … · ✓ × → ← ↑ ↓ ★ ☆ 〇 □ ■ ① ② ③".split(separator: " ").map { Candidate(String($0)) }
        }
        let personal = extra[code, default: []]
        let imported = importedIndex?.entries(for: code) ?? []
        let entries = imported.isEmpty ? personal : personal.isEmpty ? imported :
            (personal + imported).sorted { $0.weight > $1.weight }
        var words = lexicon.exact(code, extra: entries, edits: edits[code, default: [:]],
                                  includeContinuations: preferences.showContinuations)
        if preferences.singleCharacters { words.removeAll { $0.word.count != 1 } }
        if preferences.automaticallyRanks {
            words = lexicon.ranked(words, code: code, scores: ranking[code, default: [:]],
                                   edits: edits[code, default: [:]], includesFixed: preferences.rankingRange == .all)
        }
        if preferences.mixedPinyin {
            let known = Set(words.map(\.word))
            words += lexicon.compiledPinyinCandidates(for: code)
                .filter { !known.contains($0.word) && (!preferences.singleCharacters || $0.word.count == 1) }
                .map { Candidate($0.word, hint: $0.hint, source: .pinyin) }
        }
        let ordered = lexicon.applyingManualOrder(orders[code, default: []], to: words, code: code)
        // Keep exact matches in place and move unreadable continuation hints to the end.
        var visible: [Candidate] = []
        var unsupportedHints: [Candidate] = []
        for candidate in ordered {
            if !candidate.hint.isEmpty, MobileCandidateGlyphs.hasMissingExtensionGlyphs(in: candidate.word) {
                unsupportedHints.append(candidate)
            } else {
                visible.append(candidate)
            }
        }
        return visible + unsupportedHints
    }

    func record(_ selections: [Composition.Selection]) {
        guard preferences.automaticallyRanks else { return }
        for selection in selections where Entry.validCode(selection.code) {
            let frequency = ranking[selection.code]?[selection.word] ?? 0
            guard frequency < 1_000_000 else { continue }
            ranking[selection.code, default: [:]][selection.word] = frequency + 1
        }
    }

    func add(_ entry: Entry) {
        guard Entry.validCode(entry.code), !entry.word.isEmpty, entry.word.count <= 64 else { return }
        let key = "personal/\(entry.code)/\(entry.word)"
        edit { state in
            state.set(key, to: try JSONEncoder().encode(entry), device: device)
            try setEdit(WordEdit(entry.word, pinned: true), code: entry.code, in: &state)
        }
    }

    func addLearnedPhrases(_ entries: [Entry]) {
        pendingLearned.append(contentsOf: entries.filter {
            preferredCodes[$0.word] == nil && importedIndex?.contains($0.word) != true &&
                lexicon.existingCode(for: $0.word) == nil &&
                snapshot.values["personal/\($0.code)/\($0.word)"] == nil && edits[$0.code]?[$0.word]?.hidden != true
        })
        startSavingLearnedPhrases()
    }

    private func startSavingLearnedPhrases() {
        guard !pendingLearned.isEmpty, !savingLearned, !reloadingForKeyboard else { return }
        savingLearned = true
        Task { await flushLearnedPhrases() }
    }

    private func flushLearnedPhrases() async {
        while !pendingLearned.isEmpty {
            let batch = pendingLearned
            pendingLearned = []
            let previous = snapshot
            let generation = snapshotGeneration
            let cached = snapshotStamp.map { (previous, $0) }
            let keepsLibraryLists = keepsLibraryLists
            let device = device
            do {
                let (write, accepted, index) = try await Task.detached(priority: .utility) {
                    let (write, accepted) = try Self.saveLearnedPhrases(batch, device: device, reusing: cached)
                    let index = !write.reused && write.snapshot.values != previous.values
                        ? autoreleasepool { MobileSnapshotIndex(write.snapshot, keepsLibraryLists: keepsLibraryLists) }
                        : nil
                    return (write, accepted, index)
                }.value
                guard generation == snapshotGeneration else {
                    await reloadKeyboardSnapshot()
                    continue
                }
                if write.reused { applyLearned(accepted, state: write.snapshot) }
                else { apply(write.snapshot, index: index) }
                snapshotStamp = write.stamp
            } catch {
                status = "无法保存。系统键盘写入个人词库需要开启完全访问。"
            }
        }
        savingLearned = false
        if keyboardReloadPending {
            keyboardReloadPending = false
            await prepareForKeyboard()
        }
    }

    nonisolated private static func saveLearnedPhrases(_ entries: [Entry], device: String,
                                                       reusing cached: (Snapshot, MobileStorage.FileStamp)?)
        throws -> ((snapshot: Snapshot, stamp: MobileStorage.FileStamp?, reused: Bool), [Entry]) {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var accepted: [Entry] = []
        let write = try MobileStorage.update(reusing: cached) { state in
            for entry in entries {
                let key = "personal/\(entry.code)/\(entry.word)"
                guard state.values[key] == nil else { continue }
                if let data = state.values["edit/\(entry.code)/\(entry.word)"]?.value,
                   let edit = try? decoder.decode(WordEdit.self, from: data), edit.hidden { continue }
                state.set(key, to: try encoder.encode(entry), device: device)
                accepted.append(entry)
            }
        }
        return (write, accepted)
    }

    private func applyLearned(_ entries: [Entry], state: Snapshot) {
        guard !entries.isEmpty else { return }
        snapshotGeneration += 1
        snapshot = state
        for entry in entries {
            preferredCodes[entry.word] = entry.code
            // Personal entries precede imported entries of the same weight.
            var rows = extra[entry.code, default: []]
            let firstEqual = rows.firstIndex { $0.weight <= entry.weight } ?? rows.endIndex
            let index = personalEntries.firstIndex { sortPersonal(entry, before: $0, in: state) } ?? personalEntries.endIndex
            let previousPersonal = personalEntries[..<index].lazy.filter {
                $0.code == entry.code && $0.weight == entry.weight
            }.count
            rows.insert(entry, at: firstEqual + previousPersonal)
            extra[entry.code] = rows
            personalEntries.insert(entry, at: index)
        }
        if keepsLibraryLists {
            let personal = WordGroup(id: "personal", name: "个人词库", entries: personalEntries)
            if libraries.first?.id == "personal" { libraries[0] = personal }
            else { libraries.insert(personal, at: 0) }
        }
        lookupRevision += 1
    }

    func delete(_ entry: Entry) {
        edit { state in
            state.set("personal/\(entry.code)/\(entry.word)", to: nil, device: device)
            state.set("edit/\(entry.code)/\(entry.word)", to: nil, device: device)
        }
    }

    func candidateEdit(_ word: String, code: String, pinned: Bool = false, hidden: Bool = false) {
        guard Entry.validCode(code), !word.isEmpty else { return }
        edit { try setEdit(WordEdit(word, pinned: pinned, hidden: hidden), code: code, in: &$0) }
    }

    func reorder(_ rows: [Candidate], code: String, from: Int, to: Int) {
        guard let order = lexicon.manualOrder(in: rows, code: code, moving: from, to: to) else { return }
        edit { $0.set("order/" + code, to: try JSONEncoder().encode(order), device: device) }
    }

    func install(_ group: WordGroup) {
        edit { $0.set("group/" + group.id, to: try JSONEncoder().encode(group), device: device) }
    }

    func delete(_ group: WordGroup) {
        guard group.id != "personal" else { return }
        edit { $0.set("group/" + group.id, to: nil, device: device) }
    }

    func sync() async {
        guard syncEnabled else { return }
        await syncCloud(enablingWith: nil)
    }

    func enableCloud(_ resolution: CloudResolution) async {
        await syncCloud(enablingWith: resolution)
    }

    func disableCloud(restore: Bool) {
        guard !syncing else { return }
        do {
            if restore {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: MobileStorage.backup))
                guard saved.version == Snapshot.format else { throw CocoaError(.fileReadCorruptFile) }
                apply(try MobileStorage.update { $0 = saved })
            }
            syncEnabled = false
            status = "iCloud 同步已关闭。"
        } catch { status = "无法恢复开启前的本机副本。" }
    }

    private func syncCloud(enablingWith resolution: CloudResolution?) async {
        guard !syncing else { return }
        syncing = true
        status = "正在同步…"
        defer { syncing = false }
        do {
            let device = device
            let binding = UserDefaults.standard.data(forKey: "iCloudSyncAccount")
            let (cloud, signature) = try await Task.detached(priority: .utility) {
                let fm = FileManager.default
                guard let identity = fm.ubiquityIdentityToken as? NSObject,
                      let root = fm.url(forUbiquityContainerIdentifier: MobileStorage.cloud) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let signature = Data(SHA256.hash(data: try NSKeyedArchiver.archivedData(
                    withRootObject: identity, requiringSecureCoding: true)))
                guard binding == nil || binding == signature || resolution != nil else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let url = root.appendingPathComponent("Documents/Wa-Wubi", isDirectory: true)
                let local = try MobileStorage.read()
                let outbound: Snapshot
                if let resolution {
                    let remote = try CloudSnapshotFiles.read(from: url)
                    if resolution == .replaceWithCloud && remote == nil { throw CocoaError(.fileReadNoSuchFile) }
                    try FileManager.default.createDirectory(at: MobileStorage.backup.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try JSONEncoder().encode(local).write(to: MobileStorage.backup, options: .atomic)
                    outbound = local.resolved(with: remote ?? Snapshot(), using: resolution, device: device)
                } else {
                    outbound = local
                }
                let synced = try CloudSnapshotFiles.sync(outbound, in: url) {
                    guard let current = fm.ubiquityIdentityToken as? NSObject else { return false }
                    return identity.isEqual(current)
                }
                let updated = try MobileStorage.update { latest in
                    if resolution == .replaceWithCloud {
                        let edits = latest.values.filter { local.values[$0.key] != $0.value }
                        latest = synced
                        latest.merge(Snapshot(values: edits))
                    } else {
                        latest.merge(synced)
                    }
                }
                return (updated, signature)
            }.value
            apply(cloud)
            UserDefaults.standard.set(signature, forKey: "iCloudSyncAccount")
            if resolution != nil { syncEnabled = true }
            status = "已与 WA 五笔 iCloud 容器同步"
        } catch CloudSnapshotFiles.AccessError.downloading {
            status = resolution == nil ? "iCloud 正在下载文件，稍后自动重试" : "iCloud 正在下载文件，稍后再开启同步。"
        } catch {
            status = "同步失败。请检查 iCloud Drive 和应用的容器权限。"
        }
    }

    private func setEdit(_ edit: WordEdit, code: String, in state: inout Snapshot) throws {
        if edit.pinned {
            let prefix = "edit/\(code)/"
            for (key, value) in state.values where key.hasPrefix(prefix) {
                guard let data = value.value, let existing = try? JSONDecoder().decode(WordEdit.self, from: data),
                      existing.word != edit.word, existing.pinned else { continue }
                state.set(key, to: try JSONEncoder().encode(WordEdit(existing.word, hidden: existing.hidden)), device: device)
            }
        }
        state.set("edit/\(code)/\(edit.word)", to: try JSONEncoder().encode(edit), device: device)
    }

    private func edit(_ operation: (inout Snapshot) throws -> Void) {
        do {
            let write = try MobileStorage.update(reusing: snapshotStamp.map { (snapshot, $0) }, operation)
            apply(write.snapshot)
            snapshotStamp = write.stamp
        }
        catch { status = "无法保存。系统键盘写入个人词库需要开启完全访问。" }
    }

    private func apply(_ state: Snapshot, index: MobileSnapshotIndex? = nil) {
        guard index != nil || state.values != snapshot.values else { return }
        let index = index ?? MobileSnapshotIndex(state, keepsLibraryLists: keepsLibraryLists,
                                                  indexesLibraries: refreshingLibraryIndex ||
                                                    MobileSnapshotIndex.libraryRecordsChanged(from: snapshot, to: state))
        snapshotStamp = nil
        snapshotGeneration += 1
        snapshot = state
        if preferences != index.preferences { preferences = index.preferences }
        if index.indexesLibraries {
            refreshingLibraryIndex = false
            extra = index.extra
            importedIndex = index.importedIndex
            preferredCodes = index.preferredCodes
            personalEntries = index.personalEntries
            if keepsLibraryLists { libraries = index.libraries }
        }
        edits = index.edits
        orders = index.orders
        lookupRevision += 1
    }
}

private struct MobileSnapshotIndex: Sendable {
    let indexesLibraries: Bool
    let preferences: Preferences
    let personalEntries: [Entry]
    let libraries: [WordGroup]
    let extra: [String: [Entry]]
    let importedIndex: MobileLibraryIndex?
    let preferredCodes: [String: String]
    let edits: [String: [String: WordEdit]]
    let orders: [String: [Candidate]]

    static func libraryRecordsChanged(from old: Snapshot, to new: Snapshot) -> Bool {
        func isLibraryRecord(_ key: String) -> Bool { key.hasPrefix("personal/") || key.hasPrefix("group/") }
        return old.values.contains { isLibraryRecord($0.key) && new.values[$0.key] != $0.value }
            || new.values.contains { isLibraryRecord($0.key) && old.values[$0.key] == nil }
    }

    init(_ state: Snapshot, keepsLibraryLists: Bool, indexesLibraries: Bool = true) {
        self.indexesLibraries = indexesLibraries
        let decoder = JSONDecoder()
        var fields = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences()))) as? [String: Any] ?? [:]
        var personal: [Entry] = []
        var groupRecords: [(key: String, revision: Revision, data: Data)] = []
        var newEdits: [String: [String: WordEdit]] = [:]
        var newOrders: [String: [Candidate]] = [:]
        for (key, record) in state.values {
            guard let value = record.value else { continue }
            if key.hasPrefix("pref/") {
                fields[String(key.dropFirst(5))] = try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)
            } else if indexesLibraries, key.hasPrefix("personal/"), let item = try? decoder.decode(Entry.self, from: value) {
                personal.append(item)
            } else if indexesLibraries, key.hasPrefix("group/") {
                groupRecords.append((key, record.revision, value))
            } else if key.hasPrefix("edit/"), let edit = try? decoder.decode(WordEdit.self, from: value),
                      let code = key.split(separator: "/", maxSplits: 2).dropFirst().first {
                newEdits[String(code), default: [:]][edit.word] = edit
            } else if key.hasPrefix("order/") {
                newOrders[String(key.dropFirst(6))] = try? decoder.decode([Candidate].self, from: value)
            }
        }
        preferences = (try? decoder.decode(Preferences.self, from: JSONSerialization.data(withJSONObject: fields))) ?? Preferences()
        groupRecords.sort {
            $0.revision == $1.revision ? $0.key < $1.key : $0.revision < $1.revision
        }
        personal.sort { sortPersonal($0, before: $1, in: state) }
        var known: [String: String] = [:]
        for entry in personal { known[entry.word] = entry.code }
        var rows = Dictionary(grouping: personal, by: \.code)
        var groups: [WordGroup] = []
        var diskIndex: MobileLibraryIndex?
        if !keepsLibraryLists, groupRecords.reduce(0, { $0 + $1.data.count }) >= 1_048_576 {
            diskIndex = try? {
                let index = try MobileLibraryIndex()
                try index.build(personal: personal, groups: groupRecords.map(\.data))
                return index
            }()
        }
        importedIndex = diskIndex
        for record in groupRecords where diskIndex == nil {
            autoreleasepool {
                guard let group = try? decoder.decode(WordGroup.self, from: record.data) else { return }
                for entry in group.entries {
                    let code = known[entry.word] ?? entry.code
                    known[entry.word] = code
                    rows[code, default: []].append(Entry(entry.word, code, weight: entry.weight))
                }
                if keepsLibraryLists { groups.append(group) }
            }
        }
        for code in Array(rows.keys) {
            guard (rows[code]?.count ?? 0) > 1 else { continue }
            rows[code]?.sort { $0.weight > $1.weight }
        }
        extra = rows
        preferredCodes = known
        personalEntries = personal
        edits = newEdits
        orders = newOrders
        libraries = keepsLibraryLists
            ? [WordGroup(id: "personal", name: "个人词库", entries: personal)] + groups.sorted { $0.name < $1.name }
            : []
    }
}

private func sortPersonal(_ lhs: Entry, before rhs: Entry, in state: Snapshot) -> Bool {
    let lhsDate = state.values["personal/\(lhs.code)/\(lhs.word)"]?.modifiedAt ?? .distantPast
    let rhsDate = state.values["personal/\(rhs.code)/\(rhs.word)"]?.modifiedAt ?? .distantPast
    return lhsDate == rhsDate ? lhs.code < rhs.code : lhsDate < rhsDate
}
