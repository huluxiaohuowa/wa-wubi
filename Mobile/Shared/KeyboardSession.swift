import SwiftUI
import WubiCore

@MainActor final class KeyboardSession: ObservableObject {
    enum Page: String { case letters, numbers, symbols, emoji }
    enum ShiftState { case off, once, locked }

    @Published private(set) var composition = Composition()
    @Published var page: Page = .letters
    @Published private(set) var shiftState: ShiftState = .off
    @Published var compact = false
    @Published private(set) var correction: Candidate?
    @Published private(set) var modeHint = ""
    var insert: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var playClick: () -> Void = {}
    var adjustCursor: (Int) -> Void = { _ in }
    var hasFullAccess: () -> Bool = { true }
    let store: MobileStore
    private var learning = PhraseLearning()
    private var continuousLearning = ContinuousPhraseLearning()
    private var cloudTask: Task<Void, Never>?
    private var cloudCandidates: [Candidate] = []
    private var precedingText = ""
    private var hintTask: Task<Void, Never>?
    private var lastShiftTap: TimeInterval = -.infinity

    var uppercase: Bool { shiftState != .off }

    init(store: MobileStore) { self.store = store }

    func letter(_ value: Character, neighbour: Character?) {
        if uppercase {
            literal(String(value).uppercased())
            if shiftState == .once { shiftState = .off }
            return
        }
        var alternative: Candidate?
        if let neighbour, store.touchCorrection, !composition.english, composition.mode == .wubi,
           composition.code.count < 4, store.preferences.inputScheme == .wubi {
            let code = composition.code
            let primary = store.candidates(.wubi, code + String(value))
            let nearby = store.candidates(.wubi, code + String(neighbour))
            if primary.isEmpty, nearby.count == 1 { alternative = nearby.first }
        }
        key(.letter(value))
        correction = alternative
    }

    func tapShift() {
        let now = ProcessInfo.processInfo.systemUptime
        switch shiftState {
        case .off: shiftState = .once
        case .once: shiftState = now - lastShiftTap <= 0.35 ? .locked : .off
        case .locked: shiftState = .off
        }
        lastShiftTap = now
    }

    func key(_ key: Composition.Key) {
        playClick()
        correction = nil
        let previous = composition
        if key == .backspace || key == .escape {
            continuousLearning.reset()
            precedingText = ""
        }
        let result = composition.handle(key, preferences: store.preferences, lookup: lookup)
        if store.preferences.learnsPhrases == true { learning.handle(key, from: previous, to: composition) }
        commit(result)
        if !result.handled {
            switch key {
            case .backspace: deleteBackward()
            case .letter(let char), .punctuation(let char): insert(String(char))
            case .number(let number): insert(String(number))
            case .space: insert(" ")
            case .returnKey: insert("\n")
            case .semicolon: insert(";")
            case .apostrophe: insert("'")
            case .backtick: insert("`")
            default: break
            }
            precedingText = ""
        }
        if composition.code != previous.code || composition.mode != previous.mode {
            clearCloud()
            scheduleCloud()
        }
    }

    func choose(_ offset: Int) {
        correction = nil
        commit(composition.accept(index: offset, fallback: false))
        clearCloud()
    }

    func acceptCorrection() {
        guard let correction else { return }
        composition.reset()
        clearLearningContext()
        self.correction = nil
        insert(correction.word)
    }

    func toggleLanguage(physicalShift: Bool = false) {
        correction = nil
        shiftState = .off
        page = .letters
        learning.reset()
        if physicalShift { commit(composition.shiftToggleEnglish(selectsCandidate: store.preferences.shiftSelectsCandidate ?? false)) }
        else { commit(composition.toggleEnglish()) }
        clearLearningContext()
        if store.preferences.modeHints {
            modeHint = composition.english ? "英文" : store.preferences.inputScheme.title
            hintTask?.cancel()
            hintTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { self?.modeHint = "" }
            }
        }
    }

    func moveCursor(_ offset: Int) {
        guard offset != 0 else { return }
        if composition.active { commit(composition.accept(index: composition.selected, allowCloud: false)) }
        correction = nil
        clearLearningContext()
        adjustCursor(offset)
    }

    func literal(_ text: String) {
        if composition.active {
            commit(composition.accept(index: composition.selected, allowCloud: false))
        }
        if !text.isEmpty { insert(text) }
        correction = nil
        clearLearningContext()
    }

    func refreshCandidates() { composition.refresh(lookup) }

    func reset() {
        composition.reset()
        correction = nil
        clearLearningContext()
    }

    private var lookup: (Composition.Mode, String) -> [Candidate] {
        let code = composition.code
        let mode = composition.mode
        let suggestions = cloudCandidates
        return { [store] currentMode, currentCode in
            let local = store.candidates(currentMode, currentCode)
            guard !suggestions.isEmpty, mode == currentMode, code == currentCode else { return local }
            let existing = Set(local.map(\.word))
            return local + suggestions.filter { !existing.contains($0.word) }
        }
    }

    private func clearCloud() {
        cloudTask?.cancel()
        cloudTask = nil
        cloudCandidates = []
    }

    private func clearLearningContext() {
        learning.reset()
        continuousLearning.reset()
        precedingText = ""
        clearCloud()
    }

    private func scheduleCloud() {
        guard hasFullAccess(), !composition.english, composition.mode != .english,
              !store.preferences.singleCharacters, store.ready else { return }
        let config = MobileCloudPrediction.current
        let code = composition.code
        let mode = composition.mode
        guard config.enabled, (2...32).contains(code.count),
              code.utf8.allSatisfy({ (97...122).contains($0) }) else { return }
        let pinyin = mode == .pinyin || (store.preferences.mixedPinyin && code.count > 4) ? code : nil
        let seeds = composition.candidates.lazy
            .filter { (pinyin != nil || $0.hint.isEmpty) && (1...24).contains($0.word.count) &&
                $0.word.unicodeScalars.contains { $0.properties.isIdeographic } }
            .prefix(5).map(\.word)
        guard pinyin != nil || !seeds.isEmpty else { return }
        let input = CloudCandidateService.Input(pinyin: pinyin, candidates: Array(seeds), precedingText: precedingText)
        cloudTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard let self, self.hasFullAccess(), MobileCloudPrediction.current == config else { return }
                let words = try await config.suggestions(input)
                guard !Task.isCancelled, self.hasFullAccess(), MobileCloudPrediction.current == config,
                      self.composition.mode == mode, self.composition.code == code,
                      !self.store.preferences.singleCharacters else { return }
                self.cloudCandidates = words.map { Candidate($0, hint: "云联想", source: .cloud) }
                self.refreshCandidates()
            } catch {
                // Keep the local candidate list if the request fails.
            }
        }
    }

    private func commit(_ result: Composition.Result) {
        if !result.text.isEmpty {
            insert(store.preferences.traditional ? result.text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? result.text : result.text)
            if hasFullAccess(), MobileCloudPrediction.current.enabled {
                precedingText = String((precedingText + result.text).suffix(80))
            }
        }
        store.record(result.selections)
        guard hasFullAccess(), !store.preferences.singleCharacters else {
            learning.reset()
            continuousLearning.reset()
            return
        }
        var learned: [Entry] = []
        if store.preferences.learnsPhrases == true, let entry = learning.record(result, lexicon: store.lexicon) {
            learned.append(entry)
        }
        if store.preferences.learnsContinuousPhrases == true, !composition.english, composition.mode == .wubi {
            learned += continuousLearning.record(result, lexicon: store.lexicon,
                                                  maxLength: store.preferences.continuousPhraseLength ?? 4)
        } else {
            continuousLearning.reset()
        }
        store.addLearnedPhrases(learned)
    }
}
