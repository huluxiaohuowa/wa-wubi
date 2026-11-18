import SwiftUI
import UIKit
import WubiCore

struct PracticePad: UIViewRepresentable {
    let session: KeyboardSession
    let voice: MobileVoice
    let shortcut: HardwareShortcut
    var recordingShortcut: ((HardwareShortcut) -> Void)?

    func makeUIView(context: Context) -> PhysicalTextView {
        let view = PhysicalTextView()
        view.font = .preferredFont(forTextStyle: .title3)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .init(top: 14, left: 12, bottom: 14, right: 12)
        view.inputView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 1))
        view.accessibilityLabel = "练习输入框"
        view.session = session
        view.voice = voice
        session.insert = { [weak view] text in view?.insertText(text) }
        session.deleteBackward = { [weak view] in view?.deleteBackward() }
        session.adjustCursor = { [weak view] offset in
            guard let view, let range = view.selectedTextRange,
                  let position = view.position(from: range.end, offset: offset) else { return }
            view.selectedTextRange = view.textRange(from: position, to: position)
        }
        voice.result = { [weak session] in session?.literal($0) }
        return view
    }

    func updateUIView(_ view: PhysicalTextView, context: Context) {
        view.shortcut = shortcut
        view.recordingShortcut = recordingShortcut
    }
}

struct HardwareShortcut: Codable, Equatable {
    static let masks: [(UIKeyModifierFlags, String)] = [
        (.control, "Control"), (.shift, "Shift"), (.alternate, "Option"), (.command, "Command")
    ]
    static let supported = UIKeyModifierFlags(masks.map(\.0))
    static let standard = HardwareShortcut(modifiers: [.control, .shift], key: nil, keyLabel: nil)
    let mask: Int
    let key: Int?
    let keyLabel: String?

    init(modifiers: UIKeyModifierFlags, key: Int?, keyLabel: String?) {
        mask = modifiers.intersection(Self.supported).rawValue
        self.key = key
        self.keyLabel = keyLabel
    }

    var label: String {
        (Self.masks.filter { UIKeyModifierFlags(rawValue: mask).contains($0.0) }.map(\.1) + [keyLabel].compactMap { $0 })
            .joined(separator: " + ")
    }
}

@MainActor final class PhysicalTextView: UITextView {
    weak var session: KeyboardSession?
    weak var voice: MobileVoice?
    var shortcut = HardwareShortcut.standard
    var recordingShortcut: ((HardwareShortcut) -> Void)?
    private var held: Set<Int> = []
    private var voiceKey: Int?
    private var shiftOnly = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let code = key.keyCode.rawValue
            held.insert(code)
            let flags = key.modifierFlags.intersection(HardwareShortcut.supported)
            let isModifier = (0xE0...0xE7).contains(code)
            shiftOnly = isModifier && flags == .shift && held.count == 1
            if let recordingShortcut, !flags.isEmpty {
                if !isModifier || flags.rawValue.nonzeroBitCount >= 2 {
                    recordingShortcut(.init(modifiers: flags, key: isModifier ? nil : code,
                                            keyLabel: isModifier ? nil : key.charactersIgnoringModifiers.uppercased()))
                    self.recordingShortcut = nil
                }
                continue
            }
            if flags.rawValue == shortcut.mask, (shortcut.key == code || (shortcut.key == nil && isModifier)) {
                if voiceKey == nil { voiceKey = code; voice?.hold(true) }
                continue
            }
            guard flags.intersection([.command, .control, .alternate]).isEmpty,
                  let session, let mapped = map(key) else { unhandled.insert(press); continue }
            session.key(mapped)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let code = key.keyCode.rawValue
            held.remove(code)
            if voiceKey != nil, voiceKey == code || (shortcut.key == nil && (0xE0...0xE7).contains(code)) {
                voiceKey = nil
                voice?.hold(false)
                shiftOnly = false
            } else if shiftOnly, [0xE1, 0xE5].contains(code), session?.store.preferences.shiftToggle == true {
                shiftOnly = false
                session?.toggleLanguage(physicalShift: true)
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held.removeAll()
        shiftOnly = false
        if voiceKey != nil { voiceKey = nil; voice?.hold(false) }
        super.pressesCancelled(presses, with: event)
    }

    private func map(_ key: UIKey) -> Composition.Key? {
        switch key.keyCode {
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardReturnOrEnter: return .returnKey
        case .keyboardEscape: return .escape
        case .keyboardSpacebar: return .space
        case .keyboardLeftArrow: return .backward
        case .keyboardRightArrow: return .forward
        default: break
        }
        guard key.characters.count == 1, let c = key.characters.first else { return nil }
        switch c {
        case ";": return .semicolon
        case "'": return .apostrophe
        case "`": return .backtick
        case "-", "[": return session?.composition.active == true ? .previous : .punctuation(c)
        case "=", "]": return session?.composition.active == true ? .next : .punctuation(c)
        default:
            if c.isASCII, c.isLetter { return .letter(c) }
            if let number = c.wholeNumberValue { return .number(number) }
            return c.isASCII && !c.isWhitespace && !c.isNewline ? .punctuation(c) : nil
        }
    }
}
