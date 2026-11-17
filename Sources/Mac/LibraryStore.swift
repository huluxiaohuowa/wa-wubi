import AppKit
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
    @Published private(set) var pinyinReady = false
    @Published var speech = SpeechConfiguration.load() {
        didSet { speech.save() }
    }
    private(set) var lexicon = Lexicon([])
    private var pinyin: [String: [Candidate]] = [:]
    private var pinyinLoading = false
    private var extras: [String: [Entry]] = [:]
    private var edits: [String: [String: WordEdit]] = [:]
    private let device: String
    private let local = applicationSupport.appendingPathComponent("state.json")
    private var snapshot = Snapshot()
    private var cloudFolder: URL?
    private var timer: Timer?
    private var syncing = false
    private var cloudDirty = true

    private init() {
        let defaults = UserDefaults.standard
        device = defaults.string(forKey: "syncDevice") ?? UUID().uuidString
        defaults.set(device, forKey: "syncDevice")
        if let data = try? Data(contentsOf: local),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           saved.version == Snapshot.format { snapshot = saved }
        preferences.cloud = defaults.bool(forKey: "syncEnabled")
        if let path = defaults.string(forKey: "syncPath") { cloudFolder = URL(fileURLWithPath: path, isDirectory: true) }
        reload()
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Bundle.main.url(forResource: "wubi86.dict", withExtension: "yaml")
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let lexicon = Lexicon.bundled(text)
            DispatchQueue.main.async {
                self.lexicon = lexicon
                self.loading = false
                if text.isEmpty { self.status = "内置码表载入失败。" }
                if self.preferences.mixedPinyin { self.preparePinyin() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 40, repeats: true) { [weak self] _ in self?.sync() }
        if preferences.cloud { DispatchQueue.main.async { self.sync() } }
    }

    func preparePinyin(completion: (() -> Void)? = nil) {
        if pinyinReady { completion?(); return }
        guard !loading else { return }
        let lexicon = lexicon
        guard !pinyinLoading else { return }
        pinyinLoading = true
        DispatchQueue.global(qos: .utility).async {
            let index = lexicon.pinyinIndex()
            DispatchQueue.main.async {
                self.pinyin = index
                self.pinyinReady = true
                self.pinyinLoading = false
                completion?()
            }
        }
    }

    func candidates(_ mode: Composition.Mode, _ code: String) -> [Candidate] {
        if mode == .pinyin { return pinyin[code, default: []] }
        if code == "zz" {
            return ["※", "—", "…", "·", "✓", "×", "→", "←", "↑", "↓", "★", "☆", "〇", "□", "■", "①", "②", "③"].map { Candidate($0) }
        }
        let words = lexicon.exact(code, extra: extras[code, default: []], edits: edits[code, default: [:]])
        guard preferences.mixedPinyin else { return words }
        let known = Set(words.map(\.word))
        return words + pinyin[code, default: []].filter { !known.contains($0.word) }
    }

    func update(_ change: (inout Preferences) -> Void) {
        let old = preferences
        var next = old
        change(&next)
        guard next != old else { return }
        preferences = next
        if old.cloud != next.cloud { UserDefaults.standard.set(next.cloud, forKey: "syncEnabled") }
        if next.mixedPinyin { preparePinyin() }
        let encoder = JSONEncoder()
        if let before = try? encoder.encode(old), let after = try? encoder.encode(next),
           let original = try? JSONSerialization.jsonObject(with: before) as? [String: Any],
           let modified = try? JSONSerialization.jsonObject(with: after) as? [String: Any] {
            for (field, value) in modified where field != "cloud" {
                guard let new = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                      let previous = original[field],
                      let old = try? JSONSerialization.data(withJSONObject: previous, options: .fragmentsAllowed),
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
        reload()
        persist()
        sync()
    }

    func remove(_ entry: Entry) {
        snapshot.set("personal/\(entry.code)/\(entry.word)", to: nil, device: device)
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
        extras = Dictionary(grouping: groups.flatMap(\.entries), by: \.code).mapValues { entries in
            entries.enumerated().sorted { lhs, rhs in
                lhs.element.weight == rhs.element.weight ? lhs.offset < rhs.offset : lhs.element.weight > rhs.element.weight
            }.map(\.element)
        }
        edits = nextEdits
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: Self.applicationSupport, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: local, options: .atomic)
            cloudDirty = true
        } catch {
            status = "无法保存本地词库和设置。"
        }
    }

    func chooseCloudFolder() {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
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
                  FileManager.default.ubiquityIdentityToken != nil else {
                status = "请选择 iCloud Drive 内的文件夹，并确认已登录 iCloud。"
                return
            }
            let folder = base.appendingPathComponent(Self.syncFolder, isDirectory: true)
            cloudFolder = folder
            UserDefaults.standard.set(folder.path, forKey: "syncPath")
            cloudDirty = true
            if preferences.cloud { sync() }
            else { update { $0.cloud = true } }
        }
    }

    func sync() {
        guard preferences.cloud, !syncing else { return }
        guard let folder = cloudFolder else { status = "请选择 iCloud Drive 同步位置。"; return }
        guard FileManager.default.ubiquityIdentityToken != nil else { status = "iCloud Drive 当前不可用。"; return }
        let incomingSizeLimit = 128 * 1024 * 1024
        syncing = true
        let sent = snapshot
        let write = cloudDirty
        cloudDirty = false
        let ownFile = folder.appendingPathComponent(device + ".json")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var received = Snapshot()
            var message = "已读写 iCloud Drive，跨设备传输由系统完成。"
            var failed = false
            do {
                let files = FileManager.default
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let items = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [
                    .ubiquitousItemDownloadingStatusKey, .fileSizeKey
                ], options: [])
                for url in items where url.lastPathComponent != ownFile.lastPathComponent {
                    let placeholder = url.pathExtension == "icloud"
                    guard url.pathExtension == "json" || placeholder else { continue }
                    let keys = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
                    if placeholder || keys.ubiquitousItemDownloadingStatus == .notDownloaded {
                        try? files.startDownloadingUbiquitousItem(at: url)
                        message = "正在从 iCloud Drive 下载变更。"
                        continue
                    }
                    guard (keys.fileSize ?? 0) <= incomingSizeLimit else { continue }
                    var accessError: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &accessError) { actualURL in
                        if let data = try? Data(contentsOf: actualURL),
                           let remote = try? JSONDecoder().decode(Snapshot.self, from: data) {
                            received.merge(remote)
                        }
                    }
                }
                if write || !files.fileExists(atPath: ownFile.path) {
                    let data = try JSONEncoder().encode(sent)
                    var accessError: NSError?
                    var writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: ownFile, options: .forReplacing, error: &accessError) { url in
                        do { try data.write(to: url, options: .atomic) } catch { writeError = error }
                    }
                    if let error = accessError ?? writeError as NSError? { throw error }
                }
            } catch {
                message = "无法访问 iCloud Drive 同步文件夹。"
                failed = true
            }
            DispatchQueue.main.async { [weak self, received, message, failed] in
                guard let self else { return }
                self.syncing = false
                guard self.cloudFolder == folder, self.preferences.cloud else { self.sync(); return }
                if self.snapshot.merge(received) {
                    self.reload()
                    self.persist()
                    if self.preferences.mixedPinyin { self.preparePinyin() }
                }
                self.cloudDirty = self.cloudDirty || failed
                self.status = message
            }
        }
    }
}
