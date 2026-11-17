import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WubiCore

struct ApplicationSettings: View {
    @ObservedObject var store: LibraryStore
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("进入已绑定的应用时，WA 五笔按此处的默认语言启动。")
                .foregroundStyle(.secondary)
            HStack {
                Button("添加应用…", action: choose)
                Text("也可将应用拖到这里。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.preferences.appRules.keys.sorted(), id: \.self) { id in
                if let rule = store.preferences.appRules[id] {
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                        }
                        Text(rule.name)
                        Spacer()
                        Picker("默认语言", selection: Binding(
                            get: { store.preferences.appRules[id]?.language ?? .chinese },
                            set: { language in store.update { $0.appRules[id]?.language = language } }
                        )) {
                            Text("中文").tag(AppLanguage.chinese)
                            Text("英文").tag(AppLanguage.english)
                        }.labelsHidden().frame(width: 86)
                        Button("移除") { store.update { $0.appRules[id] = nil } }.buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { add(url) } }
                }
            }
            return !providers.isEmpty
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }

    private func add(_ url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
            message = "请选择一个 macOS 应用。"
            return
        }
        guard store.preferences.appRules[id] == nil else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        store.update { $0.appRules[id] = AppLanguageRule(name: name, language: .chinese) }
        message = ""
    }
}

struct PunctuationSettings: View {
    @ObservedObject var store: LibraryStore

    private enum Mode: String, CaseIterable { case chinese, english, custom }
    private let marks = Array("`~!@#$%^&*()-_=+[]{}\\|;:'\",.<>/?").map(String.init)

    private var mode: Binding<Mode> {
        Binding(get: {
            guard store.preferences.chinesePunctuation else { return .english }
            return store.preferences.customPunctuation ? .custom : .chinese
        }, set: { mode in
            store.update {
                $0.chinesePunctuation = mode != .english
                $0.customPunctuation = mode == .custom
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("标点方案", selection: mode) {
                Text("中文").tag(Mode.chinese)
                Text("英文").tag(Mode.english)
                Text("自定义").tag(Mode.custom)
            }.pickerStyle(.segmented)
            Text("Control + . 可在中文与英文标点间切换。").font(.caption).foregroundStyle(.secondary)
            if mode.wrappedValue != .english {
                Toggle("使用直角引号「」", isOn: Binding(
                    get: { store.preferences.cornerQuotes },
                    set: { value in store.update { $0.cornerQuotes = value } }
                ))
                Toggle("成对引号交替输出", isOn: Binding(
                    get: { store.preferences.pairedQuotes },
                    set: { value in store.update { $0.pairedQuotes = value } }
                ))
            }
            if mode.wrappedValue == .custom {
                Text("按键与输出标点").font(.headline)
                ForEach(marks, id: \.self) { mark in
                    HStack {
                        Text(mark).font(.body.monospaced()).frame(width: 32)
                        TextField("留空使用默认映射", text: Binding(
                            get: { store.preferences.punctuationOverrides[mark] ?? "" },
                            set: { value in
                                store.update { $0.punctuationOverrides[mark] = value.isEmpty ? nil : String(value.prefix(8)) }
                            }
                        ))
                        .accessibilityLabel("按键 \(mark) 的输出")
                    }
                }
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let logo = NSImage(named: "BrandIcon") {
                Image(nsImage: logo).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            }
            Text("WA 五笔").font(.title.weight(.semibold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                .foregroundStyle(.secondary)
            Link("官网", destination: URL(string: "https://wa-wubi.fuluwa.top/")!)
            Link("反馈问题", destination: URL(string: "https://github.com/huluxiaohuowa/wa-wubi/issues")!)
            Link("内置 86 五笔码表与许可", destination: URL(string: "https://github.com/rime/rime-wubi")!)
        }
    }
}
