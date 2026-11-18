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
    let store: MobileStore
    private var learning = PhraseLearning()
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
        let result = composition.handle(key, preferences: store.preferences, lookup: store.candidates)
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
        }
    }

    func choose(_ offset: Int) {
        correction = nil
        commit(composition.accept(index: offset))
    }

    func acceptCorrection() {
        guard let correction else { return }
        composition.reset()
        learning.reset()
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
        if composition.active { commit(composition.accept(index: composition.selected)) }
        correction = nil
        learning.reset()
        adjustCursor(offset)
    }

    func literal(_ text: String) {
        if composition.active {
            commit(composition.accept(index: composition.selected))
        }
        if !text.isEmpty { insert(text) }
        correction = nil
        learning.reset()
    }

    func refreshCandidates() { composition.refresh(store.candidates) }

    func reset() {
        composition.reset()
        correction = nil
        learning.reset()
    }

    private func commit(_ result: Composition.Result) {
        if !result.text.isEmpty {
            insert(store.preferences.traditional ? result.text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? result.text : result.text)
        }
        store.record(result.selections)
        if store.preferences.learnsPhrases == true, let entry = learning.record(result, lexicon: store.lexicon) {
            store.add(entry, learned: true)
        }
    }
}
