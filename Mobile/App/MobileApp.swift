import SwiftUI
import UIKit
import WubiCore

@main @MainActor struct WAWubiMobileApp: App {
    @StateObject private var store = MobileStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { PracticeScreen(store: store) }
                    .tabItem { Label("练习", systemImage: "keyboard") }
                NavigationStack { LibrariesScreen(store: store) }
                    .tabItem { Label("词库", systemImage: "books.vertical") }
                NavigationStack { MobileSettings(store: store) }
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                store.reload()
                while !Task.isCancelled {
                    await store.sync()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
}

private struct PracticeScreen: View {
    @ObservedObject var store: MobileStore
    @StateObject private var session: KeyboardSession
    @StateObject private var voice = MobileVoice()
    @Environment(\.horizontalSizeClass) private var widthClass
    @AppStorage("hardwareVoiceShortcut") private var shortcutData = Data()
    @State private var recordingShortcut = false

    init(store: MobileStore) {
        self.store = store
        _session = StateObject(wrappedValue: KeyboardSession(store: store))
    }

    private var shortcut: HardwareShortcut {
        (try? JSONDecoder().decode(HardwareShortcut.self, from: shortcutData)) ?? .standard
    }

    var body: some View {
        VStack(spacing: 12) {
            PracticePad(session: session, voice: voice, shortcut: shortcut, recordingShortcut: recordingAction)
                .frame(minHeight: 80)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    if recordingShortcut {
                        Text("按下要录入的实体键盘组合").font(.caption)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("practice-pad")
            if !voice.message.isEmpty {
                Text(voice.message).font(.footnote).foregroundStyle(.secondary)
            }
            if !session.compact {
                Color.clear.frame(height: practiceKeyboardHeight).allowsHitTesting(false)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            practiceKeyboard
                .accessibilityIdentifier("practice-keyboard")
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("WA 五笔")
        .onAppear { [store] in voice.profile = { [weak store] in MobileVoiceProfile(store?.preferences ?? Preferences()) } }
        .onDisappear { session.reset() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button(recordingShortcut ? "取消录入" : "录入语音快捷键") { recordingShortcut.toggle() }
                Button("恢复 Control + Shift") { shortcutData = Data() }
            } label: { Image(systemName: "keyboard.badge.ellipsis") }
            .accessibilityLabel("实体键盘快捷键")
        }
        .safeAreaInset(edge: .top) {
            if recordingShortcut {
                Text("点练习输入框，再按实体键盘组合")
                    .font(.subheadline).frame(maxWidth: .infinity)
                    .padding(8).background(.thinMaterial)
            }
        }
    }

    private var practiceKeyboardHeight: CGFloat { widthClass == .regular ? 294 : 264 }

    private var practiceKeyboard: KeyboardSurface<EmptyView> {
        let voiceAction: ((Bool) -> Void)? = MobileVoiceProfile(store.preferences).enabled ? { voice.hold($0) } : nil
        return KeyboardSurface(session: session, store: store, globe: { EmptyView() },
                               voice: voiceAction, recording: voice.recording, dockedHeight: practiceKeyboardHeight)
    }

    private var recordingAction: ((HardwareShortcut) -> Void)? {
        guard recordingShortcut else { return nil }
        return { shortcut in
            shortcutData = (try? JSONEncoder().encode(shortcut)) ?? Data()
            recordingShortcut = false
        }
    }
}
