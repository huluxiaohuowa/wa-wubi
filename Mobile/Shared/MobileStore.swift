import CryptoKit
import Foundation
import SwiftUI
import WubiCore

enum MobileStorage {
    static let group = "group.top.fuluwa.inputmethod.Wubi86"
    static let cloud = "iCloud.top.fuluwa.inputmethod.Wubi86"
    static var shared: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var local: URL {
        (shared ?? URL.applicationSupportDirectory).appendingPathComponent("mobile-state.json")
    }
    static var backup: URL { local.deletingLastPathComponent().appendingPathComponent("before-cloud.json") }

    static func read() throws -> Snapshot {
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: local))
            guard snapshot.version == Snapshot.format else { throw CocoaError(.fileReadCorruptFile) }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot()
        }
    }

    static func update(_ edit: (inout Snapshot) throws -> Void) throws -> Snapshot {
        let file = local
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var result: Result<Snapshot, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            result = Result {
                var state = try read()
                let before = state.values
                try edit(&state)
                if state.values != before || !FileManager.default.fileExists(atPath: url.path) {
                    try JSONEncoder().encode(state).write(to: url, options: .atomic)
                }
                return state
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}

@MainActor final class MobileStore: ObservableObject {
    private static let bundledLexicon = Task.detached(priority: .userInitiated) {
        guard let url = Bundle.main.url(forResource: "wubi86.dict", withExtension: "yaml") else { return nil as Lexicon? }
        return autoreleasepool { try? Lexicon.bundled(String(contentsOf: url, encoding: .utf8)) }
    }

    @Published private(set) var preferences = Preferences()
    @Published private(set) var libraries: [WordGroup] = []
    @Published private(set) var status = ""
    @Published private(set) var ready = false
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
    private(set) var lexicon = Lexicon([])
    private var pinyin: [String: [Candidate]] = [:]
    private var buildingPinyin = false
    private(set) var preferredCodes: [String: String] = [:]
    private var extra: [String: [Entry]] = [:]
    private var edits: [String: [String: WordEdit]] = [:]
    private var orders: [String: [Candidate]] = [:]
    private var ranking: [String: [String: Int]] = [:]
    var hasCloudBackup: Bool { FileManager.default.fileExists(atPath: MobileStorage.backup.path) }

    init(loadSnapshotImmediately: Bool = true) {
        if loadSnapshotImmediately { reload() }
    }

    func prepare() async {
        guard !ready else { return }
        let result = await Self.bundledLexicon.value
        guard !ready else { return }
        guard let result else { status = "无法读取 86 五笔码表"; return }
        lexicon = result
        ready = true
        preparePinyin()
    }

    func reload() {
        reloadLocalOptions()
        if let saved = try? MobileStorage.read() { apply(saved) }
    }

    func reloadForKeyboard() async {
        reloadLocalOptions()
        let generation = snapshotGeneration
        let saved = await Task.detached(priority: .userInitiated) { try? MobileStorage.read() }.value
        if !Task.isCancelled, generation == snapshotGeneration, let saved { apply(saved) }
    }

    private func reloadLocalOptions() {
        touchCorrection = defaults.bool(forKey: "touchCorrection")
        slideCorrection = defaults.object(forKey: "slideCorrection") as? Bool ?? true
        splitWideKeyboard = defaults.object(forKey: "splitWideKeyboard") as? Bool ?? true
        keySound = defaults.bool(forKey: "keySound")
        keyHaptics = defaults.bool(forKey: "keyHaptics")
        syncEnabled = defaults.bool(forKey: "mobileSyncEnabled")
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        let previous = preferences
        var next = previous
        change(&next)
        guard next != previous else { return }
        edit { try $0.updatePreferences(from: previous, to: next, device: device) }
    }

    func candidates(_ mode: Composition.Mode, _ code: String) -> [Candidate] {
        if mode == .pinyin { return pinyin[code, default: []] }
        if code == "zz", preferences.zFunction {
            return "※ — … · ✓ × → ← ↑ ↓ ★ ☆ 〇 □ ■ ① ② ③".split(separator: " ").map { Candidate(String($0)) }
        }
        var words = lexicon.exact(code, extra: extra[code, default: []], edits: edits[code, default: [:]],
                                  includeContinuations: preferences.showContinuations)
        if preferences.singleCharacters { words.removeAll { $0.word.count != 1 } }
        if preferences.automaticallyRanks {
            words = lexicon.ranked(words, code: code, scores: ranking[code, default: [:]],
                                   edits: edits[code, default: [:]], includesFixed: preferences.rankingRange == .all)
        }
        if preferences.mixedPinyin {
            let known = Set(words.map(\.word))
            words += pinyin[code, default: []]
                .filter { !known.contains($0.word) && (!preferences.singleCharacters || $0.word.count == 1) }
                .map { Candidate($0.word, hint: $0.hint, source: .pinyin) }
        }
        let ordered = lexicon.applyingManualOrder(orders[code, default: []], to: words, code: code)
        // Keep exact matches in place and move unreadable continuation hints to the end.
        var visible: [Candidate] = []
        var unsupportedHints: [Candidate] = []
        for candidate in ordered {
            if !candidate.hint.isEmpty, !MobileCandidateGlyphs.missingCodePoints(in: candidate.word).isEmpty {
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
        let newWords = entries.filter {
            preferredCodes[$0.word] == nil && lexicon.existingCode(for: $0.word) == nil &&
                snapshot.values["personal/\($0.code)/\($0.word)"] == nil && edits[$0.code]?[$0.word]?.hidden != true
        }
        guard !newWords.isEmpty else { return }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        edit { state in
            for entry in newWords {
                let key = "personal/\(entry.code)/\(entry.word)"
                guard state.values[key] == nil else { continue }
                if let data = state.values["edit/\(entry.code)/\(entry.word)"]?.value,
                   let edit = try? decoder.decode(WordEdit.self, from: data), edit.hidden { continue }
                state.set(key, to: try encoder.encode(entry), device: device)
            }
        }
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
        do { apply(try MobileStorage.update(operation)) }
        catch { status = "无法保存。系统键盘写入个人词库需要开启完全访问。" }
    }

    private func apply(_ state: Snapshot) {
        guard state.values != snapshot.values else { return }
        snapshotGeneration += 1
        snapshot = state
        let decoder = JSONDecoder()
        var fields = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences()))) as? [String: Any] ?? [:]
        var personal: [Entry] = []
        var groups: [WordGroup] = []
        var newEdits: [String: [String: WordEdit]] = [:]
        var newOrders: [String: [Candidate]] = [:]
        for (key, record) in state.values {
            guard let value = record.value else { continue }
            if key.hasPrefix("pref/") {
                fields[String(key.dropFirst(5))] = try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)
            } else if key.hasPrefix("personal/"), let item = try? decoder.decode(Entry.self, from: value) {
                personal.append(item)
            } else if key.hasPrefix("group/"), let group = try? decoder.decode(WordGroup.self, from: value) {
                groups.append(group)
            } else if key.hasPrefix("edit/"), let edit = try? decoder.decode(WordEdit.self, from: value),
                      let code = key.split(separator: "/", maxSplits: 2).dropFirst().first {
                newEdits[String(code), default: [:]][edit.word] = edit
            } else if key.hasPrefix("order/") {
                newOrders[String(key.dropFirst(6))] = try? decoder.decode([Candidate].self, from: value)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields), let p = try? decoder.decode(Preferences.self, from: data) {
            preferences = p
        }
        groups.sort {
            let lhs = state.values["group/" + $0.id]?.revision
            let rhs = state.values["group/" + $1.id]?.revision
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
        personal.sort {
            let lhs = state.values["personal/\($0.code)/\($0.word)"]?.modifiedAt ?? .distantPast
            let rhs = state.values["personal/\($1.code)/\($1.word)"]?.modifiedAt ?? .distantPast
            return lhs == rhs ? $0.code < $1.code : lhs < rhs
        }
        var known: [String: String] = [:]
        for group in groups { for entry in group.entries where known[entry.word] == nil { known[entry.word] = entry.code } }
        for entry in personal { known[entry.word] = entry.code }
        let rows = personal + groups.flatMap { $0.entries.map { Entry($0.word, known[$0.word] ?? $0.code, weight: $0.weight) } }
        extra = Dictionary(grouping: rows, by: \.code).mapValues { row in
            row.enumerated().sorted { $0.element.weight == $1.element.weight ? $0.offset < $1.offset : $0.element.weight > $1.element.weight }.map(\.element)
        }
        preferredCodes = known
        edits = newEdits
        orders = newOrders
        libraries = [WordGroup(id: "personal", name: "个人词库", entries: personal)] + groups.sorted { $0.name < $1.name }
        preparePinyin()
    }

    private func preparePinyin() {
        guard ready, preferences.inputScheme != .wubi, pinyin.isEmpty, !buildingPinyin else { return }
        buildingPinyin = true
        let lexicon = lexicon
        Task { [weak self] in
            let index = await Task.detached(priority: .utility) { autoreleasepool { lexicon.pinyinIndex() } }.value
            self?.pinyin = index
            self?.buildingPinyin = false
        }
    }
}
