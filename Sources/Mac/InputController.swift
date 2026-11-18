import AppKit
import Carbon
import InputMethodKit
import WubiCore

@objc(WAWubiInputController)
final class InputController: IMKInputController {
    private static weak var activeController: InputController?
    private static var english = false
    private let store = LibraryStore.shared
    private let speech = SpeechCapture()
    private var state = Composition()
    private var shiftPressed = false
    private var pinyinRefreshPending = false
    private var boundLanguage = false
    private var speaking = false
    private var speechShortcut: SpeechShortcut?
    private var speechHold: DispatchWorkItem?
    private var statusText: String?
    private var statusClear: DispatchWorkItem?
    private var observation: NSObjectProtocol?
    private let replacement = NSRange(location: NSNotFound, length: NSNotFound)
    private var lookup: (Composition.Mode, String) -> [Candidate] { store.candidates }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        Self.activeController = self
        let appID = (sender as? IMKTextInput)?.bundleIdentifier() ??
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let language = appID.flatMap { store.preferences.appRules[$0]?.language }
        boundLanguage = language != nil
        let english = language.map { $0 == .english } ?? Self.english
        if state.english != english { _ = state.toggleEnglish() }
        shiftPressed = false
        super.activateServer(sender)
        if observation == nil {
            observation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.stopSpeech() }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        stopSpeech()
        shiftPressed = false
        if let target = sender as? IMKTextInput, state.active { apply(state.accept(index: state.selected), to: target) }
        state.reset()
        CandidatePanel.shared.hide(for: self)
        if Self.activeController === self { Self.activeController = nil }
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
        observation = nil
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        guard let target = sender as? IMKTextInput, state.active else { return }
        apply(state.accept(index: state.selected), to: target)
        CandidatePanel.shared.hide(for: self)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let target = sender as? IMKTextInput else { return false }
        if let active = Self.activeController, active !== self { return false }
        if Self.activeController == nil { Self.activeController = self }
        if IsSecureEventInputEnabled() {
            if state.active { state.reset() }
            shiftPressed = false
            stopSpeech()
            return false
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        if handleSpeechShortcut(event, flags: flags, target: target) { return true }
        if event.type == .flagsChanged { return modifiers(event, flags: flags, target: target) }
        guard event.type == .keyDown else { return false }
        shiftPressed = false
        if speechShortcut != nil || speaking || statusText != nil { stopSpeech() }
        if flags.contains(.control), shortcut(event, flags: flags, target: target) { return true }
        if !flags.intersection([.control, .option, .command, .function]).isEmpty { return false }
        if !state.english, store.preferences.inputScheme != .wubi || (event.keyCode == 50 && !state.active) {
            warmPinyin()
        }
        guard let key = key(for: event) else {
            if state.active { apply(state.accept(index: state.selected), to: target); draw(target) }
            return false
        }
        if store.loading && !state.english { return false }
        if store.preferences.zFunction, state.code == "z", key == .space, !state.last.isEmpty {
            let word = state.last
            state.reset()
            apply(.init(true, word), to: target)
            draw(target)
            return true
        }
        let result = state.handle(key, preferences: store.preferences, lookup: lookup)
        apply(result, to: target)
        draw(target)
        return result.handled
    }

    private func warmPinyin() {
        guard !pinyinRefreshPending, !store.pinyinReady else { return }
        pinyinRefreshPending = true
        store.preparePinyin { [weak self] in
            guard let self else { return }
            self.pinyinRefreshPending = false
            guard Self.activeController === self, self.state.active, let target = self.client() else { return }
            self.state.refresh(self.lookup)
            self.draw(target)
        }
    }

    private func handleSpeechShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags, target: IMKTextInput) -> Bool {
        if let held = speechShortcut {
            shiftPressed = false
            let releasedKey = event.type == .keyUp && held.keyCode == event.keyCode
            if releasedKey || (event.type == .flagsChanged && !flags.contains(held.flags)) {
                speechHold?.cancel()
                speechHold = nil
                speechShortcut = nil
                if speaking {
                    speaking = false
                    speech.release()
                    if statusText == nil { CandidatePanel.shared.hide(for: self) }
                }
            }
            return releasedKey || (event.type == .keyDown && held.keyCode == event.keyCode)
        }
        let shortcut = store.speech.shortcut
        guard store.speech.enabled, flags == shortcut.flags else { return false }
        if let keyCode = shortcut.keyCode {
            guard event.type == .keyDown, event.keyCode == keyCode, !event.isARepeat else { return false }
        } else {
            guard event.type == .flagsChanged else { return false }
        }
        shiftPressed = false
        speechShortcut = shortcut
        let hold = DispatchWorkItem { [weak self] in
            guard let self, Self.activeController === self, self.speechShortcut == shortcut,
                  self.store.speech.enabled, self.store.speech.shortcut == shortcut else { return }
            self.speechHold = nil
            self.startSpeech(target)
        }
        speechHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: hold)
        return shortcut.keyCode != nil
    }

    private func modifiers(_ event: NSEvent, flags: NSEvent.ModifierFlags, target: IMKTextInput) -> Bool {
        guard speechShortcut == nil else { return false }
        let isShift = event.keyCode == 56 || event.keyCode == 60
        guard isShift, store.preferences.shiftToggle else { shiftPressed = false; return false }
        if flags == [.shift] { shiftPressed = true; return false }
        defer { shiftPressed = false }
        if flags.isEmpty && shiftPressed {
            apply(state.shiftToggleEnglish(selectsCandidate: store.preferences.shiftSelectsCandidate ?? true), to: target)
            if !boundLanguage { Self.english = state.english }
            if store.preferences.modeHints { notify(state.english ? "A · 英文" : "五 · 中文", at: target) }
            else { draw(target) }
        }
        return false
    }

    private func startSpeech(_ target: IMKTextInput) {
        if state.active { apply(state.accept(index: state.selected), to: target) }
        speaking = true
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let origin = caret(target)
        let selection = target.selectedRange()
        speech.begin(store.speech) { [weak self] text in
            guard let self, Self.activeController === self else { return }
            self.statusText = text
            self.draw(target)
        } completed: { [weak self] result in
            guard let self, Self.activeController === self,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  target.selectedRange() == selection, self.caret(target) == origin else {
                self?.stopSpeech()
                return
            }
            self.speaking = false
            self.statusText = nil
            switch result {
            case .success(let text):
                self.apply(.init(true, text), to: target)
                self.draw(target)
            case .failure(let error): self.notify(error.localizedDescription, at: target)
            }
        }
    }

    private func stopSpeech() {
        speechHold?.cancel()
        speechHold = nil
        speechShortcut = nil
        speech.cancel()
        speaking = false
        statusClear?.cancel()
        statusText = nil
        CandidatePanel.shared.hide(for: self)
    }

    private func notify(_ message: String, at target: IMKTextInput) {
        statusClear?.cancel()
        statusText = message
        draw(target)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusText = nil
            self.draw(target)
        }
        statusClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: item)
    }

    private func key(for event: NSEvent) -> Composition.Key? {
        if event.modifierFlags.contains(.shift), let value = event.characters?.first, value.isASCII,
           value.isPunctuation || value.isSymbol { return .punctuation(value) }
        switch event.keyCode {
        case 36, 76: return .returnKey
        case 49: return .space
        case 51: return .backspace
        case 53: return .escape
        case 123, 126: return .backward
        case 124, 125: return .forward
        case 116: return .previous
        case 121: return .next
        default: break
        }
        if !state.candidates.isEmpty {
            if [27, 33].contains(event.keyCode) { return .previous }
            if [24, 30].contains(event.keyCode) { return .next }
            if store.preferences.commaPaging {
                if event.keyCode == 43 { return .previous }
                if event.keyCode == 47 { return .next }
            }
        }
        if state.mode == .english, let value = event.characters?.first, !value.isNewline {
            return .punctuation(value)
        }
        if let value = event.characters?.first, value.isASCII {
            if value.isLetter { return .letter(value) }
            if let number = value.wholeNumberValue { return .number(number) }
            switch value {
            case ";": return .semicolon
            case "'": return .apostrophe
            case "`": return .backtick
            default: return .punctuation(value)
            }
        }
        return nil
    }

    private func shortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags, target: IMKTextInput) -> Bool {
        if flags == [.control, .option, .command] {
            if event.keyCode == 33 { openSettings(nil); return true }
            if event.keyCode == 30 { openLexicon(nil); return true }
        }
        if flags == [.control], event.keyCode == 47 {
            store.update { $0.chinesePunctuation.toggle() }
            if store.preferences.modeHints {
                notify(store.preferences.chinesePunctuation ? "中文标点" : "英文标点", at: target)
            }
            return true
        }
        if flags == [.control, .option], event.keyCode == 17 {
            toggleTraditional(nil)
            return true
        }
        if flags == [.control], event.keyCode == 24 || event.keyCode == 27 {
            let range = target.selectedRange()
            let selected = range.location != NSNotFound && range.length > 0 && range.length < 128 ?
                target.attributedSubstring(from: range)?.string : nil
            SettingsWindow.shared.open(.lexicon, word: selected ?? state.last, delete: event.keyCode == 27)
            return true
        }
        let digitKeys = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard state.mode == .wubi, flags == [.control] || flags == [.control, .shift],
              let index = digitKeys.firstIndex(of: Int(event.keyCode)), state.visible.indices.contains(index) else { return false }
        edit(index, target: target, hide: flags.contains(.shift))
        return true
    }

    private func edit(_ index: Int, target: IMKTextInput, hide: Bool) {
        guard state.mode == .wubi, state.visible.indices.contains(index) else { return }
        store.edit(state.code, state.visible[index].word, pinned: !hide, hidden: hide)
        state.refresh(lookup)
        draw(target)
    }

    private func apply(_ result: Composition.Result, to target: IMKTextInput) {
        guard !result.text.isEmpty else { return }
        let value = store.preferences.traditional ?
            result.text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? result.text : result.text
        target.insertText(value, replacementRange: replacement)
        store.record(result.selections)
    }

    private func caret(_ target: IMKTextInput) -> CGRect {
        var line = CGRect.zero
        _ = target.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        let anchor = caretAnchor(line)
        if !anchor.isEmpty { return anchor }

        let selection = target.selectedRange()
        guard selection.location != NSNotFound else { return .zero }
        let insertion = NSRange(location: selection.location, length: 0)
        return caretAnchor(target.firstRect(forCharacterRange: insertion, actualRange: nil))
    }

    private func caretAnchor(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
              rect.height.isFinite, rect.height > 0 else { return .zero }
        return CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
    }

    private func draw(_ target: IMKTextInput) {
        guard Self.activeController === self else { return }
        let label: String
        let candidates: [Candidate]
        if let statusText {
            label = statusText
            candidates = []
        } else if state.active {
            switch state.mode {
            case .wubi: label = state.code
            case .english: label = "A · " + state.code
            case .pinyin: label = "拼 · " + state.code
            }
            candidates = state.visible.map { candidate in
                guard store.preferences.traditional else { return candidate }
                return Candidate(candidate.word.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? candidate.word,
                                 hint: candidate.hint)
            }
        } else {
            CandidatePanel.shared.hide(for: self)
            return
        }
        let view = CandidateStrip(code: label, candidates: candidates, current: state.selected,
                                  page: state.page, pages: state.pageCount, preferences: store.preferences,
                                  choose: { [weak self] index in
            guard let self, Self.activeController === self else { return }
            self.apply(self.state.accept(index: index, fallback: false), to: target)
            self.draw(target)
        }, pin: state.mode == .wubi ? { [weak self] in self?.edit($0, target: target, hide: false) } : nil,
           hide: state.mode == .wubi ? { [weak self] in self?.edit($0, target: target, hide: true) } : nil,
           changePage: { [weak self] delta in
            guard let self, Self.activeController === self else { return }
            _ = self.state.handle(delta > 0 ? .next : .previous, preferences: self.store.preferences, lookup: self.lookup)
            self.draw(target)
        })
        CandidatePanel.shared.render(view, at: caret(target), for: self)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = [], checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = modifiers
            item.state = checked ? .on : .off
            menu.addItem(item)
        }

        add("设置…", #selector(openSettings(_:)), key: "[", modifiers: [.control, .option, .command])
        add("用户词库…", #selector(openLexicon(_:)), key: "]", modifiers: [.control, .option, .command])
        menu.addItem(.separator())
        let scheme = store.preferences.inputScheme
        add(InputScheme.wubi.title, #selector(useWubi(_:)), checked: scheme == .wubi)
        add(InputScheme.pinyin.title, #selector(usePinyin(_:)), checked: scheme == .pinyin)
        add(InputScheme.mixed.title, #selector(useMixed(_:)), checked: scheme == .mixed)
        menu.addItem(.separator())
        add("输简出繁", #selector(toggleTraditional(_:)), key: "t", modifiers: [.control, .option],
            checked: store.preferences.traditional)
        add(state.english ? "切换到中文" : "切换到英文", #selector(toggleLanguage(_:)))
        menu.addItem(.separator())
        add("检查更新…", #selector(checkUpdates(_:)))
        add("关于 WA 五笔", #selector(openAbout(_:)))
        add("使用指南", #selector(openGuide(_:)))
        return menu
    }

    @objc private func useWubi(_ sender: Any?) { changeScheme(to: .wubi) }
    @objc private func usePinyin(_ sender: Any?) { changeScheme(to: .pinyin) }
    @objc private func useMixed(_ sender: Any?) { changeScheme(to: .mixed) }

    private func changeScheme(to scheme: InputScheme) {
        guard store.preferences.inputScheme != scheme || state.english else { return }
        if state.english { toggleLanguage(nil) }
        if let target = client(), state.active { apply(state.accept(index: state.selected), to: target) }
        state.reset()
        store.update { $0.inputScheme = scheme }
        if let target = client() {
            if store.preferences.modeHints { notify(scheme.title, at: target) }
            else { draw(target) }
        }
    }

    @objc private func toggleTraditional(_ sender: Any?) {
        store.update { $0.traditional.toggle() }
        if let target = client() {
            if store.preferences.modeHints {
                notify(store.preferences.traditional ? "繁 · 輸簡出繁" : "简 · 简体", at: target)
            } else {
                draw(target)
            }
        }
    }

    @objc private func openSettings(_ sender: Any?) { SettingsWindow.shared.open() }
    @objc private func openLexicon(_ sender: Any?) { SettingsWindow.shared.open(.lexicon) }
    @objc private func openAbout(_ sender: Any?) { SettingsWindow.shared.open(.about) }
    @objc private func checkUpdates(_ sender: Any?) {
        SettingsWindow.shared.open(.updates)
        Task { @MainActor in UpdateManager.shared.check() }
    }

    @objc private func openGuide(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://wa-wubi.fuluwa.top/")!)
    }
    @objc private func toggleLanguage(_ sender: Any?) {
        let result = state.toggleEnglish()
        if !boundLanguage { Self.english = state.english }
        if let target = client() {
            apply(result, to: target)
            if store.preferences.modeHints { notify(state.english ? "A · 英文" : "五 · 中文", at: target) }
            else { draw(target) }
        }
    }
}
