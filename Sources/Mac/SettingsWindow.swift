import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import WubiCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance = "外观", input = "输入", lexicon = "词库", cloud = "同步", speech = "语音"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .appearance: return "slider.horizontal.3"
        case .input: return "keyboard"
        case .lexicon: return "books.vertical"
        case .cloud: return "icloud"
        case .speech: return "waveform"
        }
    }
}

final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()
    @Published var page = SettingsPage.appearance
    @Published var word = ""
    @Published var deleteWord = false
    private var window: NSWindow?

    func open(_ page: SettingsPage = .appearance, word: String = "", delete: Bool = false) {
        self.page = page
        self.word = word
        self.deleteWord = delete
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "WA 五笔设置"
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 734, height: 571))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsWindow
    @State private var themeMessage = ""
    @ObservedObject private var store = LibraryStore.shared
    @StateObject private var catalog = DictionaryCatalog(store: .shared)
    private let accent = Color(red: 0.24, green: 0.55, blue: 0.44)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let logo = NSImage(named: "BrandIcon") {
                        Image(nsImage: logo).resizable().frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                    }
                    Text("WA 五笔").font(.system(size: 17, weight: .bold))
                }
                .padding(.bottom, 18)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9).padding(.horizontal, 10)
                            .foregroundStyle(model.page == page ? accent : Color.primary)
                            .background(model.page == page ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("86 五笔 · macOS").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 136).padding(.horizontal, 17).padding(.vertical, 25)
            .background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.page.rawValue).font(.system(size: 29, weight: .bold))
                    switch model.page {
                    case .appearance: appearance
                    case .input: input
                    case .lexicon: LexiconSettings(model: model, store: store, catalog: catalog)
                    case .cloud: cloud
                    case .speech: SpeechSettings(store: store)
                    }
                }
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 734, height: 571)
        .tint(accent)
    }

    private func pref<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { store.preferences[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 15).fill(accent.opacity(0.13))
                VStack(alignment: .leading, spacing: 13) {
                    Text("候选窗预览").font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        preview
                        Text("当前预览宽度不足").font(.callout)
                    }
                }.padding(18)
            }.frame(height: store.preferences.vertical ? 215 : 114)
            HStack {
                Text("背景不透明度")
                Slider(value: pref(\.opacity), in: 0.4...1)
                Text(store.preferences.opacity.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            HStack {
                Text("候选字号")
                Slider(value: pref(\.fontSize), in: 14...28, step: 1)
                Text("\(Int(store.preferences.fontSize)) pt").monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            Picker("配色", selection: pref(\.theme)) {
                Text("跟随系统").tag(CandidateTheme.system)
                Text("松墨").tag(CandidateTheme.ink)
                Text("纸白").tag(CandidateTheme.paper)
                Text("靛蓝").tag(CandidateTheme.indigo)
            }
            HStack {
                Button("导入外观…") { importTheme() }
                Button("导出外观…") { exportTheme() }
                if !themeMessage.isEmpty { Text(themeMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Picker("候选布局", selection: pref(\.vertical)) {
                Text("横排").tag(false)
                Text("竖排").tag(true)
            }.pickerStyle(.segmented)
        }
    }

    private struct ThemeFile: Codable {
        let theme: CandidateTheme
        let opacity: Double
        let fontSize: Double
        let vertical: Bool
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 65536 else { throw ImportFailure.invalid }
            let theme = try JSONDecoder().decode(ThemeFile.self, from: Data(contentsOf: url))
            store.update {
                $0.theme = theme.theme
                $0.opacity = min(1, max(0.4, theme.opacity))
                $0.fontSize = min(28, max(14, theme.fontSize))
                $0.vertical = theme.vertical
            }
            themeMessage = "外观已应用。"
        } catch { themeMessage = "无法读取外观文件。" }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WA 五笔外观.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let prefs = store.preferences
        do {
            try JSONEncoder().encode(ThemeFile(theme: prefs.theme, opacity: prefs.opacity,
                                               fontSize: prefs.fontSize, vertical: prefs.vertical)).write(to: url, options: .atomic)
            themeMessage = "外观已导出。"
        } catch { themeMessage = "无法导出外观文件。" }
    }

    private var preview: some View {
        CandidateStrip(code: "iiii", candidates: [Candidate("洋洋洒洒"), Candidate("水"), Candidate("㵘")],
                       current: 1, page: 0, pages: 1, preferences: store.preferences)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("轻按 Shift 切换中英", isOn: pref(\.shiftToggle))
            Toggle("分号选择候选第二项", isOn: pref(\.semicolonSelect))
            Toggle("单引号选择候选第三项", isOn: pref(\.apostropheSelect))
            Toggle("四码唯一候选自动上屏", isOn: pref(\.autoCommit))
            Toggle("空码继续输入时转为英文", isOn: pref(\.emptyToEnglish))
            Toggle("五笔与拼音混输", isOn: pref(\.mixedPinyin))
            Text("反引号进入临时拼音，候选旁显示五笔编码。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("中文全角标点", isOn: pref(\.chinesePunctuation))
            Toggle("使用直角引号「」", isOn: pref(\.cornerQuotes)).disabled(!store.preferences.chinesePunctuation)
            Toggle("输简出繁", isOn: pref(\.traditional))
            DisclosureGroup("自定义标点") {
                ForEach([",", ".", "?", "!", ";", ":", "(", ")", "[", "]", "<", ">"], id: \.self) { mark in
                    HStack {
                        Text(mark).font(.body.monospaced()).frame(width: 28)
                        TextField("留空使用默认映射", text: Binding(
                            get: { store.preferences.punctuationOverrides[mark] ?? "" },
                            set: { value in
                                store.update { $0.punctuationOverrides[mark] = value.isEmpty ? nil : String(value.prefix(8)) }
                            }
                        ))
                    }
                }
            }.disabled(!store.preferences.chinesePunctuation)
        }
    }

    private var cloud: some View { CloudSettings(store: store) }
}

private struct CloudSettings: View {
    @ObservedObject var store: LibraryStore
    @State private var enable = false
    @State private var disable = false
    @State private var resolution = CloudResolution.newest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iCloud Drive").font(.title3.weight(.semibold))
            Text("在每台 Mac 上选择同一个 iCloud Drive 位置，同步词库、候选调整和输入偏好。")
                .foregroundStyle(.secondary)
            Toggle("启用 iCloud 同步", isOn: Binding(
                get: { store.preferences.cloud },
                set: { value in
                    if value {
                        if store.cloudFolder == nil, !store.chooseCloudFolder() { return }
                        resolution = .newest
                        enable = true
                    } else { disable = true }
                }
            ))
            .disabled(store.syncing)
            HStack {
                Button("选择位置…") { store.chooseCloudFolder() }.disabled(store.preferences.cloud || store.syncing)
                Button("立即同步") { store.sync() }.disabled(!store.preferences.cloud || store.syncing)
                if store.syncing { ProgressView().controlSize(.small) }
            }
            if !store.status.isEmpty { Text(store.status).font(.callout).foregroundStyle(.secondary) }
            Text("语音服务及其密钥在每台 Mac 上单独设置。").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $enable) {
            VStack(alignment: .leading, spacing: 16) {
                Text("如何开始 iCloud 同步？").font(.title2.weight(.semibold))
                Text("合并会保留两边各自新增的词库和设置。请选择如何处理改过的同一项。")
                    .foregroundStyle(.secondary)
                Picker("开启方式", selection: $resolution) {
                    Text("合并 · 较新修改优先").tag(CloudResolution.newest)
                    Text("合并 · 冲突以本机为准").tag(CloudResolution.local)
                    Text("合并 · 冲突以 iCloud 为准").tag(CloudResolution.cloud)
                    Text("直接切换到 iCloud").tag(CloudResolution.replaceWithCloud)
                }
                .pickerStyle(.radioGroup)
                Text(resolution == .replaceWithCloud ?
                     "用 iCloud 里的词库和设置替换本机当前内容。开启前的本机内容会保留为可恢复副本。" :
                     "选择只影响这次合并。开启后，同一项的后续更改以较新修改为准。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { enable = false }.keyboardShortcut(.cancelAction)
                    Button("开启同步") {
                        enable = false
                        store.enableCloud(using: resolution)
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
        .alert("关闭 iCloud 同步？", isPresented: $disable) {
            Button("保留当前结果") { store.disableCloud(restore: false) }
            if store.canRestoreBeforeCloud {
                Button("恢复开启前的本机副本") { store.disableCloud(restore: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭后，本机的后续修改只保存在这台 Mac。已经同步的数据会留在 iCloud。")
        }
    }
}

struct LexiconSettings: View {
    @ObservedObject var model: SettingsWindow
    @ObservedObject var store: LibraryStore
    @ObservedObject var catalog: DictionaryCatalog
    @State private var code = ""
    @State private var message = ""
    @State private var busy = false
    @State private var remove: WordGroup?
    @State private var personalExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("导入词库…", action: open)
                Text("SCEL、Rime YAML、TXT、TSV、CSV").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy || store.loading)
            HStack {
                TextField("字或词", text: $model.word).frame(maxWidth: 164)
                TextField("86 五笔编码", text: $code).frame(maxWidth: 112)
                Button(model.deleteWord ? "隐藏候选" : "添加") { saveWord() }
                    .disabled(model.word.trimmingCharacters(in: .whitespaces).isEmpty || store.loading)
                if model.deleteWord { Button("取消") { model.deleteWord = false } }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            Divider()
            Text("已安装").font(.headline)
            if store.groups.isEmpty { Text("已启用内置 86 五笔码表。").foregroundStyle(.secondary).font(.callout) }
            ForEach(store.groups) { group in
                if group.id == "personal" {
                    DisclosureGroup("\(group.name) · \(group.entries.count) 条", isExpanded: $personalExpanded) {
                        ForEach(group.entries, id: \.self) { entry in
                            HStack {
                                Text(entry.word)
                                Text(entry.code).monospaced().foregroundStyle(.secondary)
                                Spacer()
                                Button("删除") { store.remove(entry) }.buttonStyle(.borderless)
                            }.padding(.vertical, 2)
                        }
                    }
                } else {
                    HStack {
                        Text(group.name)
                        Text("\(group.entries.count) 条").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("移除") { remove = group }.buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            HStack {
                Text("在线词库").font(.headline)
                Spacer()
                Button("检查更新") { catalog.refresh() }.disabled(catalog.busy)
            }
            ForEach(catalog.items) { item in
                let installed = store.groups.first { $0.id == "catalog-" + item.id }
                HStack {
                    Text(item.name)
                    Link("来源", destination: item.source).font(.caption)
                    Spacer()
                    if installed?.version == item.version {
                        Label("已安装", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(installed == nil ? "安装" : "更新") { catalog.install(item) }
                            .disabled(catalog.busy || store.loading)
                    }
                }
            }
            if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { if catalog.items.isEmpty { catalog.refresh() }; inferCode() }
        .onChange(of: model.word) { _ in inferCode() }
        .alert("移除词库？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
            Button("移除", role: .destructive) { if let remove { store.remove(remove) }; remove = nil }
            Button("取消", role: .cancel) { remove = nil }
        } message: { Text("移除后，其他启用了 iCloud 同步的 Mac 也会更新。") }
    }

    private func inferCode() {
        code = store.lexicon.fullCode(for: model.word.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func saveWord() {
        let word = model.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard word.count <= 64, !word.isEmpty, Entry.validCode(typedCode) else {
            message = "请输入 1 至 4 位小写英文字母作为编码。"
            return
        }
        if model.deleteWord {
            store.edit(typedCode, word, hidden: true)
            message = "已隐藏「\(word)」。"
        } else {
            store.add(word, code: typedCode)
            message = "已添加「\(word)」。"
        }
        model.word = ""
        code = ""
        model.deleteWord = false
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["scel", "yaml", "txt", "tsv", "csv"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        guard panel.runModal() == .OK else { return }
        busy = true
        let urls = panel.urls
        let lexicon = store.lexicon
        Task { @MainActor in
            var messages: [String] = []
            for url in urls {
                do {
                    let (result, id) = try await Task.detached(priority: .utility) {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= DictionaryImport.sizeLimit else { throw ImportFailure.tooLarge }
                        let data = try Data(contentsOf: url)
                        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        return (try DictionaryImport.read(data, extension: url.pathExtension, lexicon: lexicon), id)
                    }.value
                    store.install(WordGroup(id: "import-" + id, name: url.deletingPathExtension().lastPathComponent, entries: result.entries))
                    messages.append("已导入 \(result.entries.count) 条，跳过 \(result.skipped) 条。")
                } catch {
                    messages.append(error.localizedDescription)
                }
            }
            message = messages.joined(separator: "\n")
            busy = false
        }
    }
}

struct SpeechSettings: View {
    @ObservedObject var store: LibraryStore
    @State private var key = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("启用按住说话", isOn: $store.speech.enabled)
            Text("按住 Control + Shift 直到出现「正在聆听」，松手后自动转写上屏。")
                .foregroundStyle(.secondary)
            Picker("识别服务", selection: $store.speech.provider) {
                ForEach(SpeechProvider.allCases) { provider in Text(provider.label).tag(provider) }
            }
            if store.speech.provider == .apple {
                Picker("识别语言", selection: $store.speech.locale) {
                    Text("普通话 · 中国大陆").tag("zh-CN")
                    Text("普通话 · 台湾").tag("zh-TW")
                    Text("粤语 · 香港").tag("zh-HK")
                    Text("英语 · 美国").tag("en-US")
                }
                Toggle("仅使用设备端识别", isOn: $store.speech.onDeviceOnly)
                Text("系统支持时优先在设备端识别。其他情况下，Apple Speech 可能使用苹果的服务器。")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                if store.speech.provider == .custom {
                    TextField("HTTPS 转写接口完整 URL", text: $store.speech.endpoint)
                } else {
                    Text(store.speech.provider.endpoint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                TextField("模型", text: $store.speech.model)
                HStack {
                    SecureField("API 密钥", text: $key)
                    Button("保存到钥匙串") { save(key) }.disabled(key.isEmpty)
                    Button("清除") { save("") }
                }
                Text("松开快捷键时，录音将发给你选择的转写服务。密钥仅保存在本机钥匙串。")
                    .foregroundStyle(.secondary).font(.caption)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { loadDefaults() }
        .onChange(of: store.speech.provider) { _ in
            store.speech.model = store.speech.provider.defaultModel
            loadDefaults()
        }
    }

    private func loadDefaults() {
        if store.speech.model.isEmpty { store.speech.model = store.speech.provider.defaultModel }
        key = ""
        message = SpeechKeychain.key(for: store.speech.provider).isEmpty ? "" : "此服务的密钥已保存在本机。"
    }

    private func save(_ value: String) {
        do {
            try SpeechKeychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines), for: store.speech.provider)
            loadDefaults()
        } catch { message = error.localizedDescription }
    }
}
