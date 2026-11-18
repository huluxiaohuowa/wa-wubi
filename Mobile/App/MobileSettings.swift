import SwiftUI
import WubiCore

struct MobileSettings: View {
    @ObservedObject var store: MobileStore
    @Environment(\.openURL) private var openURL
    @State private var enableSync = false
    @State private var disableSync = false
    @State private var resolution = CloudResolution.newest

    var body: some View {
        Form {
            Section("系统键盘") {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Text("在「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」添加 WA 五笔。允许完全访问后，自动加词等编辑才能写入主 App 的共享词库。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("按键平移校正", isOn: $store.slideCorrection)
                Toggle("空码就近纠正", isOn: $store.touchCorrection)
                Toggle("大屏键盘左右分区", isOn: $store.splitWideKeyboard)
                Toggle("按键音", isOn: $store.keySound)
                Toggle("按键触感", isOn: $store.keyHaptics)
            } header: {
                Text("键盘与手势")
            } footer: {
                Text("手机和浮动键盘上，按住字母左右滑动可换键。上滑输入键帽角标，双击 Shift 锁定大写，长按空格滑动光标。大屏可捏合为浮动小键盘，再用底部手柄移动。")
            }
            Section {
                NavigationLink {
                    LibrariesScreen(store: store)
                } label: {
                    Label("管理词库", systemImage: "books.vertical")
                }
                Toggle("自动加词", isOn: Binding(get: { store.preferences.learnsPhrases ?? false },
                                                     set: { value in store.updatePreferences { $0.learnsPhrases = value } }))
                Toggle("自动调序", isOn: binding(\.automaticallyRanks))
                Picker("调序范围", selection: binding(\.rankingRange)) {
                    Text("保留一级简码和键名").tag(RankingRange.ordinary)
                    Text("全部候选").tag(RankingRange.all)
                }.disabled(!store.preferences.automaticallyRanks)
                Picker("词库方案", selection: binding(\.singleCharacters)) {
                    Text("字词混合").tag(false)
                    Text("仅单字").tag(true)
                }
            } header: {
                Text("词库与学习")
            } footer: {
                Text("支持在线下载搜狗、Rime 和清华词库，也可导入本地词库文件。")
            }
            Section("输入") {
                Picker("输入方案", selection: binding(\.inputScheme)) {
                    ForEach(InputScheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("显示补全", isOn: binding(\.showContinuations))
                Toggle("自动上屏", isOn: binding(\.autoCommit))
                Toggle("第五键上屏", isOn: binding(\.fifthKeyCommits))
                Toggle("回车上屏候选", isOn: binding(\.returnSelectsCandidate))
                Toggle("空码后转英文", isOn: binding(\.emptyToEnglish))
                Toggle("分号进入临时英文", isOn: binding(\.semicolonMode))
                Toggle("启用 Z 键功能", isOn: binding(\.zFunction))
                Toggle("提示模式切换", isOn: binding(\.modeHints))
                Toggle("输简出繁", isOn: binding(\.traditional))
                Stepper("每页候选 \(store.preferences.candidateCount)", value: binding(\.candidateCount), in: 3...9)
            }
            Section("候选栏外观") {
                LabeledContent("主题", value: "跟随系统")
                Picker("候选布局", selection: binding(\.vertical)) {
                    Text("横排").tag(false)
                    Text("纵排").tag(true)
                }
                VStack(alignment: .leading) {
                    Text("字号 \(Int(store.preferences.fontSize))")
                    Slider(value: binding(\.fontSize), in: 14...28, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("不透明度 \(Int(store.preferences.opacity * 100))%")
                    Slider(value: binding(\.opacity), in: 0.4...1)
                }
            }
            Section("实体键盘与标点") {
                Toggle("Shift 切换中英文", isOn: binding(\.shiftToggle))
                Picker("Shift 切换时上屏", selection: Binding(
                    get: { store.preferences.shiftSelectsCandidate ?? false },
                    set: { value in store.updatePreferences { $0.shiftSelectsCandidate = value } }
                )) {
                    Text("原始编码").tag(false)
                    Text("首选候选").tag(true)
                }
                Toggle("分号选词", isOn: binding(\.semicolonSelect))
                Toggle("单引号选词", isOn: binding(\.apostropheSelect))
                Toggle("逗号句号翻页", isOn: binding(\.commaPaging))
                Toggle("中文标点", isOn: binding(\.chinesePunctuation))
                Toggle("成对引号", isOn: binding(\.pairedQuotes))
                Toggle("直角引号", isOn: binding(\.cornerQuotes))
                Toggle("自定义标点", isOn: binding(\.customPunctuation))
                NavigationLink("标点映射") { PunctuationSettings(store: store) }
            }
            Section("同步") {
                Toggle("同步设置和词库", isOn: Binding(
                    get: { store.syncEnabled },
                    set: { enabled in
                        if enabled { resolution = .newest; enableSync = true }
                        else { disableSync = true }
                    }
                )).disabled(store.syncing)
                if store.syncEnabled {
                    Button("立即同步") { Task { await store.sync() } }.disabled(store.syncing)
                }
                if !store.status.isEmpty { Text(store.status).font(.footnote).foregroundStyle(.secondary) }
                Text("与 Mac 使用同一 Apple 账户。iPhone 和 iPad 自动访问已有容器，无需选择目录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("语音与关于") {
                NavigationLink("语音") { VoiceSettings(store: store) }
                Link("使用指南", destination: URL(string: "https://wa-wubi.fuluwa.top/")!)
                Link("隐私政策", destination: URL(string: "https://wa-wubi.fuluwa.top/privacy.html")!)
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $enableSync) {
            NavigationStack {
                Form {
                    Picker("首次同步", selection: $resolution) {
                        Text("合并 · 较新修改优先").tag(CloudResolution.newest)
                        Text("合并 · 冲突以本机为准").tag(CloudResolution.local)
                        Text("合并 · 冲突以 iCloud 为准").tag(CloudResolution.cloud)
                        Text("直接使用 iCloud 数据").tag(CloudResolution.replaceWithCloud)
                    }
                    Text("开启前会保存一份本机词库及设置。")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("开启同步")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { enableSync = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("开启") {
                            enableSync = false
                            Task { await store.enableCloud(resolution) }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("关闭 iCloud 同步？", isPresented: $disableSync) {
            Button("保留当前词库和设置") { store.disableCloud(restore: false) }
            if store.hasCloudBackup { Button("恢复开启前的本机副本") { store.disableCloud(restore: true) } }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: key] },
                set: { value in store.updatePreferences { $0[keyPath: key] = value } })
    }
}

private struct PunctuationSettings: View {
    @ObservedObject var store: MobileStore
    @State private var source = ""
    @State private var output = ""

    var body: some View {
        Form {
            Section("添加映射") {
                TextField("原符号", text: $source)
                TextField("输出", text: $output)
                Button("保存") {
                    let key = source
                    let value = output
                    store.updatePreferences { $0.punctuationOverrides[key] = value }
                    source = ""; output = ""
                }
                .disabled(source.count != 1 || output.isEmpty)
            }
            ForEach(store.preferences.punctuationOverrides.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: store.preferences.punctuationOverrides[key] ?? "")
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            store.updatePreferences { $0.punctuationOverrides.removeValue(forKey: key) }
                        }
                    }
            }
        }
        .navigationTitle("标点映射")
    }
}

private struct VoiceSettings: View {
    @ObservedObject var store: MobileStore
    private var profile: MobileVoiceProfile { MobileVoiceProfile(store.preferences) }
    @AppStorage("hardwareVoiceShortcut") private var shortcut = Data()
    @State private var secret = ""
    @State private var saves = ""

    var body: some View {
        Form {
            Toggle("启用语音转写", isOn: bind(\.enabled))
            Picker("语音服务", selection: bind(\.service)) {
                ForEach(VoiceService.allCases) { Text($0.label).tag($0) }
            }
            if profile.service == .apple {
                TextField("语种地区代码", text: bind(\.locale)).autocorrectionDisabled()
                Toggle("仅设备端识别", isOn: bind(\.localOnly))
            } else {
                if profile.service == .custom {
                    TextField("HTTPS 转写地址", text: bind(\.endpoint))
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                }
                TextField(profile.service.suggestedModel.isEmpty ? "模型" : profile.service.suggestedModel, text: bind(\.model))
                    .textInputAutocapitalization(.never)
                SecureField("服务密钥", text: $secret)
                Button("保存到本机钥匙串") {
                    saves = MobileVoice.saveToken(secret, for: profile.service) ? "已保存" : "保存失败"
                    secret = ""
                }
                if !saves.isEmpty { Text(saves).font(.footnote).foregroundStyle(.secondary) }
                Text("选择在线服务后，录音仅在松手确认后发送给这个服务。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("实体键盘") {
                LabeledContent("当前快捷键", value: ((try? JSONDecoder().decode(HardwareShortcut.self, from: shortcut)) ?? .standard).label)
                Text("到练习页的键盘菜单录入组合键。长按说话，松手结束。")
            }
        }
        .onChange(of: profile.service) { _, _ in secret = ""; saves = "" }
        .navigationTitle("语音")
    }

    private func bind<T>(_ key: WritableKeyPath<MobileVoiceProfile, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: key] }, set: { value in
            var next = profile
            next[keyPath: key] = value
            store.updatePreferences { $0.speechConfiguration = next.encoded() }
        })
    }
}
