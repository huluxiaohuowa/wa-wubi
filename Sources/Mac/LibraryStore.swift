import AppKit
import CryptoKit
import SwiftUI
import WubiCore

struct WordGroup: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var entries: [Entry]
    var version: String?
}

final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    static let syncFolder = "WA 五笔同步"
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WA 五笔", isDirectory: true)

    @Published private(set) var preferences = Preferences()
    @Published private(set) var groups: [WordGroup] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = true
    @Published private(set) var syncing = false
    @Published private(set) var cloudFolder: URL?
    @Published private(set) var pinyinReady = false
    @Published var speech = SpeechConfiguration.load() {
        didSet { speech.save() }
    }
    private(set) var lexicon = Lexicon([])
    private var pinyin: [String: [Candidate]] = [:]
    private var pinyinLoading = false
    private var pinyinCallbacks: [() -> Void] = []
    private var extras: [String: [Entry]] = [:]
    private(set) var preferredImportCodes: [String: String] = [:]
    private var edits: [String: [String: WordEdit]] = [:]
    private let device: String
    private let local = applicationSupport.appendingPathComponent("state.json")
    private var snapshot = Snapshot()
    private let rankingFile = applicationSupport.appendingPathComponent("candidate-ranking.json")
    private var ranking: [String: [String: Int]] = [:]
    private var rankSave: DispatchWorkItem?
    private var cloudIdentity: Data?
    private var timer: Timer?
    private var cloudDirty = true
    private let beforeCloud = applicationSupport.appendingPathComponent("before-cloud.json")

    var canRestoreBeforeCloud: Bool { FileManager.default.fileExists(atPath: beforeCloud.path) }

    private init() {
        let defaults = UserDefaults.standard
        device = defaults.string(forKey: "syncDevice") ?? UUID().uuidString
        defaults.set(device, forKey: "syncDevice")
        if let data = try? Data(contentsOf: local),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           saved.version == Snapshot.format { snapshot = saved }
        if let data = try? Data(contentsOf: rankingFile),
           let saved = try? JSONDecoder().decode([String: [String: Int]].self, from: data) { ranking = saved }
        preferences.cloud = defaults.bool(forKey: "syncEnabled")
        if let path = defaults.string(forKey: "syncPath") { cloudFolder = URL(fileURLWithPath: path, isDirectory: true) }
        cloudIdentity = defaults.data(forKey: "syncIdentity")
        reload()
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Bundle.main.url(forResource: "wubi86.dict", withExtension: "yaml")
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let lexicon = Lexicon.bundled(text)
            DispatchQueue.main.async {
                self.lexicon = lexicon
                self.loading = false
                if text.isEmpty { self.status = "内置码表载入失败。" }
                if self.preferences.inputScheme != .wubi || !self.pinyinCallbacks.isEmpty { self.preparePinyin() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 40, repeats: true) { [weak self] _ in self?.sync() }
        if preferences.cloud { DispatchQueue.main.async { self.sync() } }
    }

    func preparePinyin(completion: (() -> Void)? = nil) {
        if pinyinReady { completion?(); return }
        if let completion { pinyinCallbacks.append(completion) }
        guard !loading, !pinyinLoading else { return }
        let lexicon = lexicon
        pinyinLoading = true
        DispatchQueue.global(qos: .utility).async {
            let index = lexicon.pinyinIndex()
            DispatchQueue.main.async {
                self.pinyin = index
                self.pinyinReady = true
                self.pinyinLoading = false
                let callbacks = self.pinyinCallbacks
                self.pinyinCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    func candidates(_ mode: Composition.Mode, _ code: String) -> [Candidate] {
        if mode == .pinyin { return pinyin[code, default: []] }
        if code == "zz", preferences.zFunction {
            return ["※", "—", "…", "·", "✓", "×", "→", "←", "↑", "↓", "★", "☆", "〇", "□", "■", "①", "②", "③"].map { Candidate($0) }
        }
        var words = lexicon.exact(code, extra: extras[code, default: []], edits: edits[code, default: [:]],
                                  includeContinuations: preferences.showContinuations)
        if preferences.singleCharacters {
            words = words.filter { $0.word.count == 1 }
        }
        if preferences.automaticallyRanks {
            words = lexicon.ranked(words, code: code, scores: ranking[code, default: [:]],
                                   edits: edits[code, default: [:]], includesFixed: preferences.rankingRange == .all)
        }
        guard preferences.mixedPinyin else { return words }
        let known = Set(words.map(\.word))
        return words + pinyin[code, default: []].filter { !known.contains($0.word) && (!preferences.singleCharacters || $0.word.count == 1) }
    }

    func record(_ selections: [Composition.Selection]) {
        guard preferences.automaticallyRanks, !selections.isEmpty else { return }
        var changed = false
        for selection in selections where Entry.validCode(selection.code) {
            let isProtected = lexicon.isFixedWord(selection.word) || (selection.code.count == 1 &&
                candidates(.wubi, selection.code).prefix(Lexicon.protectedShortcutCount(for: selection.code)).contains { $0.word == selection.word })
            if isProtected && preferences.rankingRange == .ordinary { continue }
            let amount = ranking[selection.code]?[selection.word] ?? 0
            guard amount < 1_000_000, amount > 0 || ranking[selection.code, default: [:]].count < 128 else { continue }
            ranking[selection.code, default: [:]][selection.word] = amount + 1
            changed = true
        }
        guard changed else { return }
        rankSave?.cancel()
        let action = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: Self.applicationSupport, withIntermediateDirectories: true)
                try JSONEncoder().encode(self.ranking).write(to: self.rankingFile, options: .atomic)
            } catch { self.status = "无法保存候选词使用顺序。" }
        }
        rankSave = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: action)
    }

    func update(_ change: (inout Preferences) -> Void) {
        let old = preferences
        var next = old
        change(&next)
        next.cloud = old.cloud
        guard next != old else { return }
        preferences = next
        if next.inputScheme != .wubi { preparePinyin() }
        let encoder = JSONEncoder()
        if let before = try? encoder.encode(old), let after = try? encoder.encode(next),
           let original = try? JSONSerialization.jsonObject(with: before) as? [String: Any],
           let modified = try? JSONSerialization.jsonObject(with: after) as? [String: Any] {
            for (field, value) in modified where field != "cloud" {
                guard let new = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                      let previous = original[field],
                      let old = try? JSONSerialization.data(withJSONObject: previous, options: [.fragmentsAllowed, .sortedKeys]),
                      new != old else { continue }
                snapshot.set("pref/" + field, to: new, device: device)
            }
        }
        persist()
        sync()
    }

    func edit(_ code: String, _ word: String, pinned: Bool = false, hidden: Bool = false) {
        guard Entry.validCode(code), !word.isEmpty, word.count <= 64 else { return }
        if pinned {
            for item in edits[code, default: [:]].values where item.pinned && item.word != word {
                set("edit/\(code)/\(item.word)", WordEdit(item.word))
            }
        }
        set("edit/\(code)/\(word)", WordEdit(word, pinned: pinned, hidden: hidden))
        reload()
        persist()
        sync()
    }

    func add(_ word: String, code: String) {
        let group = groups.first(where: { $0.id == "personal" }) ?? WordGroup(id: "personal", name: "手动加词", entries: [])
        guard !group.entries.contains(where: { $0.word == word && $0.code == code }) else { return }
        let entry = Entry(word, code)
        set("personal/\(code)/\(word)", entry)
        edit(code, word, pinned: true)
    }

    func remove(_ entry: Entry) {
        snapshot.set("personal/\(entry.code)/\(entry.word)", to: nil, device: device)
        snapshot.set("edit/\(entry.code)/\(entry.word)", to: nil, device: device)
        reload()
        persist()
        sync()
    }

    func replacePersonal(with entries: [Entry]) {
        let existing = Set(groups.first(where: { $0.id == "personal" })?.entries ?? [])
        let replacement = Set(entries)
        for entry in existing.subtracting(replacement) {
            snapshot.set("personal/\(entry.code)/\(entry.word)", to: nil, device: device)
            snapshot.set("edit/\(entry.code)/\(entry.word)", to: nil, device: device)
        }
        for entry in replacement.subtracting(existing) {
            set("personal/\(entry.code)/\(entry.word)", entry)
        }
        reload()
        persist()
        sync()
    }

    func install(_ group: WordGroup) {
        set("group/" + group.id, group)
        reload()
        persist()
        sync()
    }

    func remove(_ group: WordGroup) {
        guard group.id != "personal" else { return }
        snapshot.set("group/" + group.id, to: nil, device: device)
        reload()
        persist()
        sync()
    }

    private func set<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { snapshot.set(key, to: data, device: device) }
    }

    private func reload() {
        let decoder = JSONDecoder()
        let localCloud = preferences.cloud
        let data = (try? JSONEncoder().encode(Preferences())) ?? Data()
        var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var nextGroups: [WordGroup] = []
        var personal: [Entry] = []
        var nextEdits: [String: [String: WordEdit]] = [:]
        for (key, change) in snapshot.values {
            guard let value = change.value else { continue }
            if key.hasPrefix("pref/"), let item = try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed) {
                fields[String(key.dropFirst(5))] = item
            } else if key.hasPrefix("group/"), let group = try? decoder.decode(WordGroup.self, from: value) {
                nextGroups.append(group)
            } else if key.hasPrefix("personal/"), let entry = try? decoder.decode(Entry.self, from: value) {
                personal.append(entry)
            } else if key.hasPrefix("edit/"), let edit = try? decoder.decode(WordEdit.self, from: value),
                      let code = key.split(separator: "/", maxSplits: 2).dropFirst().first {
                nextEdits[String(code), default: [:]][edit.word] = edit
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields),
           var decoded = try? decoder.decode(Preferences.self, from: data) {
            decoded.cloud = localCloud
            decoded.opacity = min(1, max(0.4, decoded.opacity))
            decoded.fontSize = min(28, max(14, decoded.fontSize))
            preferences = decoded
        }
        personal.sort { $0.code == $1.code ? $0.word < $1.word : $0.code < $1.code }
        if !personal.isEmpty { nextGroups.append(WordGroup(id: "personal", name: "手动加词", entries: personal)) }
        groups = nextGroups.sorted {
            if $0.id == "personal" || $1.id == "personal" { return $0.id == "personal" }
            return $0.id < $1.id
        }
        let olderPackages = nextGroups.filter { $0.id != "personal" }.sorted {
            let first = snapshot.values["group/" + $0.id]?.revision
            let second = snapshot.values["group/" + $1.id]?.revision
            if let first, let second, first != second { return first < second }
            return $0.id < $1.id
        }
        var known: [String: String] = [:]
        for group in olderPackages {
            for entry in group.entries where known[entry.word] == nil { known[entry.word] = entry.code }
        }
        let manualByDate = personal.sorted { lhs, rhs in
            let first = snapshot.values["personal/\(lhs.code)/\(lhs.word)"]
            let second = snapshot.values["personal/\(rhs.code)/\(rhs.word)"]
            let firstTime = first?.modifiedAt ?? .distantPast
            let secondTime = second?.modifiedAt ?? .distantPast
            if firstTime != secondTime { return firstTime < secondTime }
            if let first, let second, first.revision != second.revision { return first.revision < second.revision }
            return lhs.code < rhs.code
        }
        for entry in manualByDate { known[entry.word] = entry.code }
        preferredImportCodes = known
        let canonical = personal + olderPackages.flatMap { group in
            group.entries.map { entry in Entry(entry.word, known[entry.word] ?? entry.code, weight: entry.weight) }
        }
        extras = Dictionary(grouping: canonical, by: \.code).mapValues { entries in
            entries.enumerated().sorted { lhs, rhs in
                lhs.element.weight == rhs.element.weight ? lhs.offset < rhs.offset : lhs.element.weight > rhs.element.weight
            }.map(\.element)
        }
        edits = nextEdits
    }

    private func persist() {
        do {
            try save(snapshot, to: local)
            cloudDirty = true
        } catch {
            status = "无法保存本地词库和设置。"
        }
    }

    private func save(_ state: Snapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: Self.applicationSupport, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private var cloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private func saveCloudLocation(_ folder: URL, identity: Data) {
        cloudFolder = folder
        cloudIdentity = identity
        UserDefaults.standard.set(folder.path, forKey: "syncPath")
        UserDefaults.standard.set(identity, forKey: "syncIdentity")
    }

    @discardableResult
    func chooseCloudFolder() -> Bool {
        guard !preferences.cloud, !syncing else { return false }
        let drive = cloudDrive
        let opener = NSOpenPanel()
        opener.canChooseFiles = false
        opener.canChooseDirectories = true
        opener.canCreateDirectories = false
        opener.directoryURL = drive
        opener.prompt = "选择 iCloud Drive"
        opener.message = "请选择 iCloud Drive 或其中的文件夹。每台 Mac 选择相同位置。"
        if opener.runModal() == .OK, let base = opener.url {
            let basePath = base.resolvingSymlinksInPath().path
            let drivePath = drive.resolvingSymlinksInPath().path
            guard basePath == drivePath || basePath.hasPrefix(drivePath + "/"),
                  let identity = currentCloudIdentity() else {
                status = "请选择 iCloud Drive 内的文件夹，并确认已登录 iCloud。"
                return false
            }
            let folder = base.appendingPathComponent(Self.syncFolder, isDirectory: true)
            saveCloudLocation(folder, identity: identity)
            status = "同步位置已选定。"
            return true
        }
        return false
    }

    func enableCloud(using resolution: CloudResolution) {
        guard !preferences.cloud, !syncing else { return }
        guard let identity = currentCloudIdentity(),
              (try? cloudDrive.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            status = "iCloud Drive 当前不可用。请在系统设置中开启 iCloud Drive 后重试。"
            return
        }
        if let cloudIdentity, identity != cloudIdentity {
            status = "iCloud 帐户已变更。请选择此帐号的同步位置。"
            return
        }
        let folder = cloudFolder ?? cloudDrive.appendingPathComponent(Self.syncFolder, isDirectory: true)
        syncing = true
        status = "正在读取 iCloud Drive 词库和设置…"
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try CloudSnapshotFiles.read(from: folder) }
            DispatchQueue.main.async {
                self.syncing = false
                guard identity == self.currentCloudIdentity() else {
                    self.status = "iCloud 帐户已变更，请重新选择同步位置。"
                    return
                }
                do {
                    let remote = try result.get()
                    if resolution == .replaceWithCloud && remote == nil {
                        self.status = "iCloud 中还没有同步数据。本机词库和设置保持原样。"
                        return
                    }
                    let settled = self.snapshot.resolved(with: remote ?? Snapshot(), using: resolution, device: self.device)
                    try self.save(self.snapshot, to: self.beforeCloud)
                    try self.save(settled, to: self.local)
                    self.snapshot = settled
                    self.saveCloudLocation(folder, identity: identity)
                    self.setCloudEnabled(true)
                    self.reload()
                    self.cloudDirty = resolution != .replaceWithCloud
                    if self.preferences.inputScheme != .wubi { self.preparePinyin() }
                    self.status = "已启用 iCloud 同步。"
                    self.sync()
                } catch {
                    self.status = self.cloudMessage(for: error)
                }
            }
        }
    }

    func disableCloud(restore: Bool) {
        guard preferences.cloud, !syncing else { return }
        if restore {
            do {
                let backup = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: beforeCloud))
                guard backup.version == Snapshot.format else { throw CocoaError(.fileReadCorruptFile) }
                setCloudEnabled(false)
                try save(backup, to: local)
                snapshot = backup
                reload()
                if preferences.inputScheme != .wubi { preparePinyin() }
                status = "同步已关闭，已恢复开启前的本机词库和设置。"
            } catch {
                status = "无法恢复本机副本。当前词库和设置保持原样。"
            }
        } else {
            setCloudEnabled(false)
            status = "同步已关闭，已保留当前词库和设置。"
        }
    }

    private func setCloudEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "syncEnabled")
        preferences.cloud = enabled
    }

    private func currentCloudIdentity() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken,
              let archive = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return nil }
        return Data(SHA256.hash(data: archive))
    }

    func sync() {
        guard preferences.cloud, !syncing else { return }
        guard let folder = cloudFolder else { status = "请选择 iCloud Drive 同步位置。"; return }
        guard let identity = currentCloudIdentity() else { status = "iCloud Drive 当前不可用。"; return }
        guard identity == cloudIdentity else { status = "iCloud 帐户已变更，请关闭同步后重新选择位置。"; return }
        syncing = true
        let sent = snapshot
        let write = cloudDirty
        let device = device
        cloudDirty = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                let received = try CloudSnapshotFiles.read(from: folder, excluding: device)
                guard self?.currentCloudIdentity() == identity else { throw CocoaError(.fileWriteNoPermission) }
                if write { try CloudSnapshotFiles.write(sent, in: folder, device: device) }
                return received
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncing = false
                guard self.cloudFolder == folder, self.preferences.cloud else { return }
                switch result {
                case .success(let received):
                    if let received, self.snapshot.merge(received) {
                        self.reload()
                        self.persist()
                        if self.preferences.inputScheme != .wubi { self.preparePinyin() }
                    }
                    self.status = "已读写 iCloud Drive，跨设备传输由系统完成。"
                case .failure(let error):
                    self.cloudDirty = self.cloudDirty || write
                    self.status = self.cloudMessage(for: error)
                }
            }
        }
    }

    private func cloudMessage(for error: Error) -> String {
        switch error {
        case CloudSnapshotFiles.AccessError.downloading:
            return "正在下载 iCloud 数据，稍后再试。"
        case CloudSnapshotFiles.AccessError.invalidSnapshot:
            return "iCloud 同步数据无法读取。现有词库和设置保持原样。"
        default:
            return "无法访问同步位置或保存本机数据。请检查 iCloud Drive 后再试。"
        }
    }
}
