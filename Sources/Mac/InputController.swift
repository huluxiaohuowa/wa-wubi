import AppKit
import Carbon
import InputMethodKit
import WubiCore

@objc(WAWubiInputController)
final class InputController: IMKInputController {
    private static weak var activeController: InputController?
    private static var english = false
    private static var showingSpeechPermission = false
    private let store = LibraryStore.shared
    private let speech = SpeechCapture()
    private var state = Composition()
    private var phraseLearning = PhraseLearning()
    private var continuousLearning = ContinuousPhraseLearning()
    private var learningCaret: NSRange?
    private var shiftPressed = false
    private var pinyinRefreshPending = false
    private var boundLanguage = false
    private var compositionMarked = false
    private var consumedKeyDowns = Set<UInt16>()
    private var speaking = false
    private var speechShortcut: SpeechShortcut?
    private var speechHold: DispatchWorkItem?
    private var statusText: String?
    private var statusClear: DispatchWorkItem?
    private var observation: NSObjectProtocol?
    private var cloudObservation: NSObjectProtocol?
    private var predictionTask: Task<Void, Never>?
    private var glossTask: Task<Void, Never>?
    private var cloudSuggestions: [Candidate] = []
    private var glossRequest: [String] = []
    private var glosses: [String: String] = [:]
    private var precedingText = ""
    private let replacement = NSRange(location: NSNotFound, length: NSNotFound)
    private var lookup: (Composition.Mode, String) -> [Candidate] {
        let mode = state.mode
        let code = state.code
        let suggestions = cloudSuggestions
        return { [store] requestedMode, requestedCode in
            let local = store.candidates(requestedMode, requestedCode)
            guard requestedMode == mode, requestedCode == code, !suggestions.isEmpty else { return local }
            let words = Set(local.map(\.word))
            return local + suggestions.filter { !words.contains($0.word) }
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        Self.activeController = self
        phraseLearning.reset()
        resetContinuousLearning()
        precedingText = ""
        let appID = (sender as? IMKTextInput)?.bundleIdentifier() ??
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        consumedKeyDowns.removeAll()
        let language = appID.flatMap { store.preferences.appRules[$0]?.language }
        boundLanguage = language != nil
        let english = language.map { $0 == .english } ?? Self.english
        if state.english != english { _ = state.toggleEnglish() }
        shiftPressed = false
        super.activateServer(sender)
        if observation == nil {
            observation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.stopSpeech()
                self?.invalidateCloudContext()
                self?.resetContinuousLearning()
            }
        }
        if cloudObservation == nil {
            cloudObservation = NotificationCenter.default.addObserver(
                forName: CloudPredictionConfiguration.didChange, object: nil, queue: .main
            ) { [weak self] _ in self?.invalidateCloudContext() }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        stopSpeech()
        clearCloud()
        precedingText = ""
        phraseLearning.reset()
        resetContinuousLearning()
        shiftPressed = false
        if let target = sender as? IMKTextInput {
            if state.active { apply(state.accept(index: state.selected, allowCloud: false), to: target) }
            setCompositionMark(false, in: target)
        }
        compositionMarked = false
        consumedKeyDowns.removeAll()
        state.reset()
        CandidatePanel.shared.hide(for: self)
        if Self.activeController === self { Self.activeController = nil }
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
        observation = nil
        if let cloudObservation { NotificationCenter.default.removeObserver(cloudObservation) }
        cloudObservation = nil
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        guard let target = sender as? IMKTextInput, state.active else { return }
        phraseLearning.reset()
        resetContinuousLearning()
        apply(state.accept(index: state.selected, allowCloud: false), to: target)
        clearCloud()
        setCompositionMark(false, in: target)
        CandidatePanel.shared.hide(for: self)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let target = sender as? IMKTextInput else { return false }
        if let active = Self.activeController, active !== self { return false }
        if Self.activeController == nil { Self.activeController = self }
        if IsSecureEventInputEnabled() {
            phraseLearning.reset()
            resetContinuousLearning()
            clearCloud()
            precedingText = ""
            if state.active { state.reset() }
            setCompositionMark(false, in: target)
            consumedKeyDowns.removeAll()
            shiftPressed = false
            stopSpeech()
            CandidatePanel.shared.hide(for: self)
            return false
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        let handledBySpeech = handleSpeechShortcut(event, flags: flags, target: target)
        if event.type == .flagsChanged { return modifiers(event, flags: flags, target: target) }
        if event.type == .keyUp {
            let consumed = consumedKeyDowns.remove(event.keyCode) != nil
            return handledBySpeech || consumed
        }
        guard event.type == .keyDown else { return false }
        let handled = handledBySpeech || handleKeyDown(event, flags: flags, target: target)
        if handled { consumedKeyDowns.insert(event.keyCode) }
        else { consumedKeyDowns.remove(event.keyCode) }
        return handled
    }

    private func handleKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags, target: IMKTextInput) -> Bool {
        shiftPressed = false
        if speechShortcut != nil || speaking || statusText != nil { stopSpeech() }
        if !flags.intersection([.control, .option, .command, .function]).isEmpty {
            phraseLearning.reset()
            resetContinuousLearning()
            invalidateCloudContext()
        }
        if flags.contains(.control), shortcut(event, flags: flags, target: target) { return true }
        if !flags.intersection([.control, .option, .command, .function]).isEmpty { return false }
        if !state.english, store.preferences.inputScheme != .wubi || (event.keyCode == 50 && !state.active) {
            warmPinyin()
        }
        guard let key = key(for: event) else {
            phraseLearning.reset()
            resetContinuousLearning()
            if state.active { apply(state.accept(index: state.selected, allowCloud: false), to: target); draw(target) }
            invalidateCloudContext()
            return false
        }
        if store.loading && !state.english { return false }
        if key == .backspace || key == .escape || state.english ||
            (!state.active && learningCaret.map { $0 != target.selectedRange() } == true) {
            resetContinuousLearning()
        }
        let oldCode = state.code
        let oldMode = state.mode
        let previous = store.preferences.learnsPhrases == true && !store.preferences.singleCharacters ? state : nil
        let result: Composition.Result
        if store.preferences.zFunction, state.code == "z", key == .space, !state.last.isEmpty {
            let word = state.last
            state.reset()
            result = .init(true, word)
        } else {
            result = state.handle(key, preferences: store.preferences, lookup: lookup)
        }
        apply(result, to: target)
        if let previous { phraseLearning.handle(key, from: previous, to: state) }
        recordLearnedPhrase(result)
        recordContinuousPhrases(result, at: target)
        let changedComposition = state.code != oldCode || state.mode != oldMode
        if changedComposition { clearCloud() }
        if !result.handled || state.english { precedingText = "" }
        draw(target)
        if changedComposition { schedulePrediction(at: target) }
        return result.handled
    }

    private func clearCloud() {
        predictionTask?.cancel()
        predictionTask = nil
        glossTask?.cancel()
        glossTask = nil
        cloudSuggestions = []
        glossRequest = []
        glosses = [:]
    }

    private func invalidateCloudContext() {
        let hadSuggestions = !cloudSuggestions.isEmpty
        clearCloud()
        precedingText = ""
        if hadSuggestions { state.refresh(store.candidates) }
        if state.active, !IsSecureEventInputEnabled(), let target = client() { draw(target, requestGlosses: false) }
    }

    private func schedulePrediction(at target: IMKTextInput) {
        let config = CloudPredictionConfiguration.current
        guard config.enabled, !state.english, state.mode != .english,
              (2...32).contains(state.code.count),
              state.code.utf8.allSatisfy({ (97...122).contains($0) }),
              target.bundleIdentifier() != Bundle.main.bundleIdentifier,
              !IsSecureEventInputEnabled() else { return }
        let code = state.code
        let mode = state.mode
        let pinyin = mode == .pinyin || (store.preferences.mixedPinyin && code.count > 4) ? code : nil
        let seeds = localChineseWords(state.candidates, exactOnly: pinyin == nil, limit: 5)
        guard pinyin != nil || !seeds.isEmpty else { return }
        let input = CloudPrediction.Input(pinyin: pinyin, candidates: seeds, precedingText: precedingText)
        let selection = target.selectedRange()
        predictionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
                guard let self, self.canShowCloud(at: target, selection: selection, config: config),
                      self.state.code == code, self.state.mode == mode else { return }
                let suggestions = try await CloudPrediction.suggestions(input, config: config)
                guard !Task.isCancelled, self.canShowCloud(at: target, selection: selection, config: config),
                      self.state.code == code, self.state.mode == mode else { return }
                self.cloudSuggestions = suggestions.map { Candidate($0, hint: "云联想", source: .cloud) }
                self.state.refresh(self.lookup)
                self.draw(target)
            } catch {
                // Local candidates stay available if the service is unavailable.
            }
        }
    }

    private func scheduleGlosses(at target: IMKTextInput) {
        let config = CloudPredictionConfiguration.current
        guard LanguageLearning.isEnabled, !IsSecureEventInputEnabled() else { return }
        let words = localChineseWords(state.visible, exactOnly: false, limit: state.pageSize)
        guard words != glossRequest else { return }
        glossTask?.cancel()
        glossRequest = words
        glosses = [:]
        guard !words.isEmpty else { return }
        let usesCloud = config.enabled && config.showsGlosses == true
        let language = usesCloud ? config.translationLanguage : "英语"
        let cloudSelection = usesCloud && target.bundleIdentifier() != Bundle.main.bundleIdentifier
            ? target.selectedRange() : nil
        glossTask = Task { @MainActor [weak self] in
            let offline = await LanguageLearning.offlineTranslations(for: words, language: language)
            guard let self, !Task.isCancelled, LanguageLearning.isEnabled,
                  Self.activeController === self, self.state.active, !self.state.english,
                  !IsSecureEventInputEnabled(), CloudPredictionConfiguration.current == config,
                  self.glossRequest == words else { return }
            if !offline.isEmpty {
                self.glosses = offline
                self.draw(target, requestGlosses: false)
            }
            let missing = words.filter { offline[$0] == nil }
            guard let selection = cloudSelection, !missing.isEmpty else { return }
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
                guard LanguageLearning.isEnabled, self.canShowCloud(at: target, selection: selection, config: config) else { return }
                let translations = try await CloudPrediction.glosses(missing, config: config)
                guard !Task.isCancelled, LanguageLearning.isEnabled,
                      self.canShowCloud(at: target, selection: selection, config: config),
                      self.glossRequest == words else { return }
                self.glosses.merge(translations) { local, _ in local }
                self.draw(target, requestGlosses: false)
            } catch {
                // A failed translation leaves the original candidate labels visible.
            }
        }
    }

    private func canShowCloud(at target: IMKTextInput, selection: NSRange, config: CloudPredictionConfiguration) -> Bool {
        Self.activeController === self && state.active && !state.english && !speaking &&
            !IsSecureEventInputEnabled() && target.selectedRange() == selection &&
            CloudPredictionConfiguration.current == config
    }

    private func localChineseWords(_ candidates: [Candidate], exactOnly: Bool, limit: Int) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for candidate in candidates {
            guard words.count < limit else { break }
            let word = candidate.word
            guard !candidate.isCloud, !exactOnly || candidate.hint.isEmpty,
                  (1...24).contains(word.count),
                  word.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
                  seen.insert(word).inserted else { continue }
            words.append(word)
        }
        return words
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

    private func recordLearnedPhrase(_ result: Composition.Result) {
        guard store.preferences.learnsPhrases == true, !store.preferences.singleCharacters else {
            phraseLearning.reset()
            return
        }
        if let entry = phraseLearning.record(result, lexicon: store.lexicon) { store.addLearnedPhrases([entry]) }
    }

    private func resetContinuousLearning() {
        continuousLearning.reset()
        learningCaret = nil
    }

    private func recordContinuousPhrases(_ result: Composition.Result, at target: IMKTextInput) {
        guard store.preferences.learnsContinuousPhrases == true, !store.preferences.singleCharacters,
              state.mode == .wubi, !state.english, !IsSecureEventInputEnabled() else {
            resetContinuousLearning()
            return
        }
        let learned = continuousLearning.record(result, lexicon: store.lexicon,
                                                maxLength: store.preferences.continuousPhraseLength ?? 4)
        if !result.handled || (!result.text.isEmpty && result.selections.map(\.word).joined() != result.text) {
            learningCaret = nil
        } else if !result.text.isEmpty {
            let range = target.selectedRange()
            learningCaret = range.location == NSNotFound ? nil : range
        }
        store.addLearnedPhrases(learned)
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
            phraseLearning.reset()
            resetContinuousLearning()
            invalidateCloudContext()
            apply(state.shiftToggleEnglish(selectsCandidate: store.preferences.shiftSelectsCandidate ?? true), to: target)
            if !boundLanguage { Self.english = state.english }
            if store.preferences.modeHints { notify(state.english ? "A · 英文" : "五 · 中文", at: target) }
            else { draw(target) }
        }
        return false
    }

    private func startSpeech(_ target: IMKTextInput) {
        phraseLearning.reset()
        resetContinuousLearning()
        if state.active { apply(state.accept(index: state.selected, allowCloud: false), to: target) }
        invalidateCloudContext()
        speaking = true
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let origin = caret(target)
        let selection = target.selectedRange()
        speech.begin(store.speech) { [weak self] text in
            guard let self, Self.activeController === self else { return }
            self.statusText = text
            self.draw(target)
        } completed: { [weak self] result in
            guard let self, Self.activeController === self else { return }
            if case .failure(let error) = result, let pane = (error as? SpeechError)?.privacyPane {
                self.stopSpeech()
                Self.showSpeechPermission(name: pane.name, anchor: pane.anchor)
                return
            }
            guard
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  target.selectedRange() == selection, self.caret(target) == origin else {
                self.stopSpeech()
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

    private static func showSpeechPermission(name: String, anchor: String) {
        guard !showingSpeechPermission else { return }
        showingSpeechPermission = true
        defer { showingSpeechPermission = false }
        let alert = NSAlert()
        alert.messageText = "WA 五笔需要\(name)权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → \(name)」中允许 WA 五笔，然后再次按住语音快捷键。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        if !NSWorkspace.shared.open(URL(string: "\(privacy)?\(anchor)")!) {
            NSWorkspace.shared.open(URL(string: privacy)!)
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
        guard state.mode == .wubi, state.visible.indices.contains(index), state.visible[index].isDictionaryEditable else { return }
        store.edit(state.code, state.visible[index].word, pinned: !hide, hidden: hide)
        resetContinuousLearning()
        clearCloud()
        state.refresh(lookup)
        draw(target)
    }

    private func moveCandidate(from source: Int, to destination: Int, target: IMKTextInput) {
        guard Self.activeController === self, state.mode == .wubi else { return }
        let offset = state.page * state.pageSize
        guard state.visible.indices.contains(source), state.visible.indices.contains(destination) else { return }
        guard let order = store.lexicon.manualOrder(in: state.candidates, code: state.code,
                                                   moving: offset + source, to: offset + destination) else { return }
        store.saveCandidateOrder(order, for: state.code)
        state.refresh(lookup)
        draw(target)
    }

    private func apply(_ result: Composition.Result, to target: IMKTextInput) {
        guard !result.text.isEmpty else { return }
        let value = store.preferences.traditional ?
            result.text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? result.text : result.text
        compositionMarked = false
        target.insertText(value, replacementRange: replacement)
        store.record(result.selections)
        if CloudPredictionConfiguration.current.enabled {
            precedingText = String((precedingText + value).suffix(80))
        }
    }

    private func setCompositionMark(_ active: Bool, in target: IMKTextInput) {
        guard compositionMarked != active else { return }
        compositionMarked = active
        // Some clients need a marked range to suppress raw keys. Keep the code in the candidate panel.
        target.setMarkedText(active ? "\u{3000}" : "", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: replacement)
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

    private func draw(_ target: IMKTextInput, requestGlosses: Bool = true) {
        guard Self.activeController === self else { return }
        setCompositionMark(state.active, in: target)
        let label: String
        let candidates: [Candidate]
        var translations: [String]?
        if let statusText {
            label = statusText
            candidates = []
        } else if state.active {
            switch state.mode {
            case .wubi: label = state.code
            case .english: label = "A · " + state.code
            case .pinyin: label = "拼 · " + state.code
            }
            if LanguageLearning.isEnabled, state.mode != .english {
                translations = state.visible.map { glosses[$0.word] ?? "" }
            }
            candidates = state.visible.map { candidate in
                let word = store.preferences.traditional
                    ? candidate.word.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? candidate.word
                    : candidate.word
                return Candidate(word, hint: candidate.hint, source: candidate.source)
            }
        } else {
            CandidatePanel.shared.hide(for: self)
            return
        }
        let offset = state.page * state.pageSize
        let movable = statusText == nil && state.mode == .wubi ? Set(state.visible.indices.filter { index in
            store.lexicon.canMoveCandidate(state.visible[index], at: offset + index, code: state.code)
        }) : []
        let view = CandidateStrip(code: label, candidates: candidates, current: state.selected,
                                  page: state.page, pages: state.pageCount, preferences: store.preferences,
                                  translations: translations,
                                  choose: { [weak self] index in
            guard let self, Self.activeController === self, !IsSecureEventInputEnabled() else { return }
            let result = self.state.accept(index: index, fallback: false)
            self.apply(result, to: target)
            self.recordLearnedPhrase(result)
            self.recordContinuousPhrases(result, at: target)
            self.clearCloud()
            self.draw(target)
        }, pin: state.mode == .wubi ? { [weak self] in self?.edit($0, target: target, hide: false) } : nil,
           hide: state.mode == .wubi ? { [weak self] in self?.edit($0, target: target, hide: true) } : nil,
           changePage: { [weak self] delta in
            guard let self, Self.activeController === self else { return }
            _ = self.state.handle(delta > 0 ? .next : .previous, preferences: self.store.preferences, lookup: self.lookup)
            self.draw(target)
        }, movable: movable, move: { [weak self] source, destination in
            self?.moveCandidate(from: source, to: destination, target: target)
        })
        CandidatePanel.shared.render(view, at: caret(target), for: self)
        if requestGlosses, statusText == nil, state.mode != .english { scheduleGlosses(at: target) }
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
        if CloudPredictionConfiguration.current.enabled {
            menu.addItem(.separator())
            add("问字…", #selector(askCloudCharacter(_:)))
            add("翻译选中文字…", #selector(translateSelection(_:)))
        }
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
        if let target = client(), state.active { apply(state.accept(index: state.selected, allowCloud: false), to: target) }
        state.reset()
        resetContinuousLearning()
        invalidateCloudContext()
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
    @objc private func askCloudCharacter(_ sender: Any?) {
        guard CloudPredictionConfiguration.current.enabled, !IsSecureEventInputEnabled() else { return }
        let alert = NSAlert()
        alert.messageText = "问字"
        alert.informativeText = "输入字形、部件或读音，例如「三个木组成什么字」。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "查询")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        requestCloudAnswer(title: "问字", input: String(question.prefix(200)),
                           instruction: "根据用户描述回答可能的汉字，简明说明读音、字义和组成。")
    }

    @objc private func translateSelection(_ sender: Any?) {
        let config = CloudPredictionConfiguration.current
        guard config.enabled, !IsSecureEventInputEnabled(), let target = client() else { return }
        let range = target.selectedRange()
        guard range.location != NSNotFound, (1...1500).contains(range.length),
              let text = target.attributedSubstring(from: range)?.string, !text.isEmpty else {
            Self.showCloudAnswer(title: "翻译选中文字", text: "请选中 1–1500 个字符后再试。")
            return
        }
        requestCloudAnswer(title: "翻译", input: String(text.prefix(1500)),
                           instruction: "将用户给出的文本翻译成\(config.translationLanguage)。只返回译文。")
    }

    private func requestCloudAnswer(title: String, input: String, instruction: String) {
        let config = CloudPredictionConfiguration.current
        guard config.enabled, !IsSecureEventInputEnabled() else { return }
        Task { @MainActor in
            do {
                let result = try await CloudPrediction.complete(instruction: instruction, input: input, config: config)
                guard CloudPredictionConfiguration.current == config, !IsSecureEventInputEnabled() else { return }
                Self.showCloudAnswer(title: title, text: result)
            } catch {
                guard CloudPredictionConfiguration.current == config, !IsSecureEventInputEnabled() else { return }
                Self.showCloudAnswer(title: title, text: error.localizedDescription)
            }
        }
    }

    private static func showCloudAnswer(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSTextView.scrollableTextView()
        scroll.frame.size = NSSize(width: 360, height: 140)
        if let content = scroll.documentView as? NSTextView {
            content.isEditable = false
            content.isSelectable = true
            content.string = text
            content.font = .systemFont(ofSize: 14)
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleLanguage(_ sender: Any?) {
        resetContinuousLearning()
        let result = state.toggleEnglish()
        invalidateCloudContext()
        if !boundLanguage { Self.english = state.english }
        if let target = client() {
            apply(result, to: target)
            if store.preferences.modeHints { notify(state.english ? "A · 英文" : "五 · 中文", at: target) }
            else { draw(target) }
        }
    }
}
