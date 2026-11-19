import CoreText
import SwiftUI
import UIKit
import WubiCore

private enum KeyboardLayout {
    static let compactKeyInset: CGFloat = 3
    static let compactCornerRadius: CGFloat = 7
    static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let upper = ["1234567890", "@#¥%&*-+=", "()!….,?"]
    static let numbers = [Array("1234567890"), Array("-/:;()¥@“”"), Array(".,\\?!·")]
    static let englishNumbers = [numbers[0], Array("-/:;()$@\"'"), Array(".,\\?!·")]
    static let symbols = [Array("【】{}#%^*+="), Array("_—\\|~《》$&·"), Array("…，‘?!’")]
    static let englishSymbols = [Array("[]{}#%^*+="), Array("_-\\|~<>$&·"), Array("…,\"?!'")]
    static let thumbPunctuation = [Array(".,\\?!"), Array("-/:;@"), Array("()¥“”")]
    static let thumbEnglishPunctuation = [Array(".,?!'"), Array("-/:;@"), Array("()$\"&")]
    static let thumbSymbols = [Array("【】{}#"), Array("《》%&*"), Array("…_\\|~")]
    static let thumbEnglishSymbols = [Array("[]{}#"), Array("<>%&*"), Array("…_\\|~")]
    static let keypad = [Array("789"), Array("456"), Array("123"), Array("0.,")]
}

struct KeyboardSurface<Globe: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: KeyboardSession
    @ObservedObject var store: MobileStore
    let globe: () -> Globe
    var voice: ((Bool) -> Void)?
    var recording = false
    var showGlobe = false
    var dockedHeight: CGFloat?
    var usesSystemBackdrop = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
    @State private var floatingOffset: CGSize = .zero
    @State private var slidingKey: Character?
    @GestureState private var dragOffset: CGSize = .zero

    private var keyColor: Color {
        colorScheme == .dark ? Color(red: 0.37, green: 0.37, blue: 0.39) : .white
    }
    private var functionColor: Color {
        colorScheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color(red: 0.76, green: 0.77, blue: 0.80)
    }
    private var keyBorder: Color { colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.04) }

    private func tapFeedback() {
        if store.keyHaptics { haptic.impactOccurred() }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let wide = width >= 580
            let floating = wide && session.compact
            let split = wide && !floating && store.splitWideKeyboard
            let panelWidth = floating ? 398 : width
            let panelHeight = min(geometry.size.height, floating ? 246 : (dockedHeight ?? geometry.size.height))
            let compact = !wide || floating
            let sideInset: CGFloat = compact ? 1 : (UIDevice.current.userInterfaceIdiom == .phone ? 48 : 5)
            let contentWidth = panelWidth - 2 * sideInset
            let rowInset = compact ? max(2, min(5.5, (panelHeight - (floating ? 225 : 210)) / 10)) : 3
            let travel = CGSize(width: (width - panelWidth) / 2, height: geometry.size.height - panelHeight)
            let offset = floating ? boundedOffset(travel: travel, translation: dragOffset) : .zero
            VStack(spacing: 0) {
                candidateBar(wide: wide, compact: compact)
                if split && session.page != .emoji {
                    thumbKeyboard(width: contentWidth)
                } else if session.page == .emoji {
                    EmojiPalette { tapFeedback(); session.literal($0) }
                    toolbar(width: contentWidth, compact: compact, rowInset: rowInset)
                } else {
                    keyRows(width: contentWidth, compact: compact, rowInset: rowInset)
                    toolbar(width: contentWidth, compact: compact, rowInset: rowInset)
                }
                if floating { dragHandle(travel: travel) }
            }
            .padding(.horizontal, sideInset)
            .padding(.top, 3)
            .padding(.bottom, 4)
            .frame(width: panelWidth, height: panelHeight)
            .background {
                if floating || !usesSystemBackdrop {
                    keyboardBackdrop(floating: floating)
                }
            }
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                guard wide else { return }
                if value.magnification < 0.82 { session.compact = true }
                if value.magnification > 1.18 { session.compact = false }
            })
            .offset(x: offset.width, y: offset.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onChange(of: wide) { _, isWide in if !isWide { session.compact = false } }
        }
    }

    private func boundedOffset(travel: CGSize, translation: CGSize) -> CGSize {
        let x = min(travel.width, max(-travel.width, floatingOffset.width))
        let y = min(0, max(-travel.height, floatingOffset.height))
        return CGSize(width: min(travel.width, max(-travel.width, x + translation.width)),
                      height: min(0, max(-travel.height, y + translation.height)))
    }

    private func dragHandle(travel: CGSize) -> some View {
        Capsule()
            .fill(.secondary)
            .frame(width: 48, height: 4)
            .frame(width: 112, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .updating($dragOffset) { value, offset, _ in offset = value.translation }
                .onEnded { value in floatingOffset = boundedOffset(travel: travel, translation: value.translation) })
            .accessibilityLabel("拖动浮动键盘")
            .accessibilityAdjustableAction { direction in
                let x: CGFloat = direction == .increment ? 36 : -36
                floatingOffset = boundedOffset(travel: travel, translation: CGSize(width: x, height: 0))
            }
    }

    private func keyboardBackdrop(floating: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: floating ? 24 : 0,
                                          bottomTrailingRadius: floating ? 24 : 0, topTrailingRadius: 24)
        let tint = colorScheme == .dark ? Color.black.opacity(0.24) : Color(uiColor: .systemGray4).opacity(0.48)
        return ZStack {
            shape.fill(tint)
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(tint), in: shape)
            } else {
                shape.fill(.thinMaterial).overlay { shape.fill(tint) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func candidateBar(wide: Bool, compact: Bool) -> some View {
        let c = session.composition
        return HStack(spacing: 5) {
            if showGlobe { globe().frame(width: 40, height: 40) }
            if !c.code.isEmpty {
                Text(c.code).font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).padding(.leading, 5)
            }
            if c.code.isEmpty && session.modeHint.isEmpty && store.ready {
                Spacer(minLength: 0)
                ClipboardPasteButton { session.literal($0) }
                Spacer(minLength: 0)
            } else {
                candidateScroll(c)
            }
            if c.pageCount > 1 {
                Button { session.key(.previous) } label: { Image(systemName: "chevron.left") }
                    .disabled(c.page == 0).accessibilityLabel("上一页")
                Button { session.key(.next) } label: { Image(systemName: "chevron.right") }
                    .disabled(c.page + 1 == c.pageCount).accessibilityLabel("下一页")
            }
            if compact {
                if c.code.isEmpty { emojiKey(chrome: true).frame(width: 39, height: 40) }
                languageKey(chrome: true).frame(width: 39, height: 40)
            }
            if wide {
                functionKey(session.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                            label: session.compact ? "恢复大键盘" : "缩成手机键盘") { session.compact.toggle() }
                    .frame(width: 38, height: 36)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .frame(height: 43)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(c.code.isEmpty ? 0 : store.preferences.opacity * 0.55),
                    in: UnevenRoundedRectangle(topLeadingRadius: 19, bottomLeadingRadius: 9,
                                               bottomTrailingRadius: 9, topTrailingRadius: 19))
    }

    @ViewBuilder private func candidateScroll(_ composition: Composition) -> some View {
        let scroll = ScrollView(.horizontal) {
            HStack(spacing: 3) { candidateItems(composition) }
        }
        .scrollIndicators(.hidden)
        if #available(iOS 26.0, *) {
            scroll.scrollEdgeEffectHidden()
        } else {
            scroll
        }
    }

    @ViewBuilder private func candidateItems(_ c: Composition) -> some View {
        ForEach(Array(c.visible.enumerated()), id: \.offset) { i, item in
            Button { tapFeedback(); session.choose(i) } label: {
                HStack(spacing: 4) {
                    let missing = MobileCandidateGlyphs.missingCodePoints(in: item.word)
                    if missing.isEmpty {
                        Text(item.word)
                            .font(.system(size: min(28, max(14, store.preferences.fontSize)), weight: .medium))
                    } else {
                        Text(missing.map { "U+" + String($0, radix: 16, uppercase: true) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .accessibilityLabel("系统字体缺字，字符编码 " + missing.map { String($0, radix: 16, uppercase: true) }.joined(separator: "、"))
                    }
                    if !item.hint.isEmpty { Text(item.hint).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8).frame(minHeight: 38)
                .foregroundStyle(i == c.selected ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !item.isCloud {
                    Button("置顶") { store.candidateEdit(item.word, code: c.code, pinned: true); session.reset() }
                    Button("前移") {
                        let index = c.page * c.pageSize + i
                        store.reorder(c.candidates, code: c.code, from: index, to: index - 1)
                        session.refreshCandidates()
                    }
                    Button("后移") {
                        let index = c.page * c.pageSize + i
                        store.reorder(c.candidates, code: c.code, from: index, to: index + 1)
                        session.refreshCandidates()
                    }
                    Button("隐藏", role: .destructive) { store.candidateEdit(item.word, code: c.code, hidden: true); session.reset() }
                }
            }
        }
        if let correction = session.correction {
            Button("纠错 · " + correction.word) { session.acceptCorrection() }.font(.footnote).padding(.horizontal, 6)
        }
        if c.visible.isEmpty && !session.modeHint.isEmpty {
            Text(session.modeHint).font(.footnote).foregroundStyle(.secondary).padding(.leading, 8)
        }
        if !store.ready {
            Text("正在准备码表…").foregroundStyle(.secondary).font(.footnote)
        }
    }

    private func keyRows(width: CGFloat, compact: Bool, rowInset: CGFloat) -> some View {
        let letters = session.page == .letters
        let english = session.composition.english
        let rows: [[Character]]
        switch session.page {
        case .letters, .emoji: rows = KeyboardLayout.rows.map { Array($0) }
        case .numbers: rows = english ? KeyboardLayout.englishNumbers : KeyboardLayout.numbers
        case .symbols: rows = english ? KeyboardLayout.englishSymbols : KeyboardLayout.symbols
        }
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                let unit = width / 10
                let edgeWidth = compact ? unit * 1.22 : 54
                let thirdRowGap = compact && letters && index == 2 ? unit * 0.28 : 0
                let horizontalInset = compact ? KeyboardLayout.compactKeyInset : 2.5
                HStack(spacing: 0) {
                    if index == 2 {
                        rowModeKey(letters: letters, horizontalInset: horizontalInset, rowInset: rowInset)
                            .frame(width: edgeWidth)
                        if thirdRowGap > 0 { Color.clear.frame(width: thirdRowGap).allowsHitTesting(false) }
                    }
                    keys(row, range: row.indices, index: index, letters: letters,
                         keyWidth: compact && letters ? unit : nil, slides: compact && store.slideCorrection,
                         horizontalInset: horizontalInset, rowInset: rowInset, titleSize: compact ? 24 : 22)
                    if index == 2 {
                        if thirdRowGap > 0 { Color.clear.frame(width: thirdRowGap).allowsHitTesting(false) }
                        functionKey("delete.left", label: "删除", horizontalInset: horizontalInset, rowInset: rowInset) {
                            session.key(.backspace)
                        }
                        .frame(width: edgeWidth)
                    }
                }
                .padding(.horizontal, !compact && letters && index == 1 ? 18 : 0)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func thumbKeyboard(width: CGFloat) -> some View {
        let groupWidth = min(308, (width - 68) / 2)
        let unit = groupWidth / 5.85
        let letters = session.page == .letters
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                if letters {
                    thumbLetters(left: true, unit: unit)
                } else {
                    let english = session.composition.english
                    let rows = session.page == .numbers
                        ? (english ? KeyboardLayout.thumbEnglishPunctuation : KeyboardLayout.thumbPunctuation)
                        : (english ? KeyboardLayout.thumbEnglishSymbols : KeyboardLayout.thumbSymbols)
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(spacing: 0) {
                            if index == 2 { rowModeKey(letters: false).frame(width: unit * 0.85) }
                            keys(rows[index], range: rows[index].indices, index: index, letters: false, keyWidth: unit)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 4) {
                    pageModeKey.frame(width: unit)
                    emojiKey.frame(width: unit * 0.88)
                    languageKey.frame(width: unit * 0.88)
                    spaceKey
                }
                .padding(.top, 3)
                .frame(height: 43)
            }
            .frame(width: groupWidth)
            Spacer(minLength: 40)
            if letters {
                VStack(spacing: 0) {
                    thumbLetters(left: false, unit: unit)
                    HStack(spacing: 4) {
                        spaceKey
                        if let voice { VoiceHoldButton(active: recording, onHold: voice).frame(width: unit) }
                        functionKey("return", label: "回车") { session.key(.returnKey) }.frame(width: unit * 1.35)
                    }
                    .padding(.top, 3)
                    .frame(height: 43)
                }
                .frame(width: groupWidth)
            } else {
                thumbNumberPad.frame(width: groupWidth * 0.88)
            }
        }
        .padding(.horizontal, 4)
    }

    private func thumbLetters(left: Bool, unit: CGFloat) -> some View {
        ForEach(KeyboardLayout.rows.indices, id: \.self) { index in
            let row = Array(KeyboardLayout.rows[index])
            HStack(spacing: 0) {
                if index == 2 && left { rowModeKey(letters: true).frame(width: unit * 0.85) }
                if index == 1 { Spacer().frame(width: unit * 0.28) }
                if index == 2 && !left { Spacer().frame(width: unit * 0.55) }
                keys(row, range: left ? 0..<5 : 5..<row.count, index: index, letters: true, keyWidth: unit)
                Spacer(minLength: 0)
                if index == 2 && !left {
                    functionKey("delete.left", label: "删除") { session.key(.backspace) }
                        .padding(.vertical, 3)
                        .frame(width: unit * 1.12)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var thumbNumberPad: some View {
        VStack(spacing: 0) {
            ForEach(KeyboardLayout.keypad.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(KeyboardLayout.keypad[index], id: \.self) { character in
                        TouchKey(title: String(character), color: keyColor, border: keyBorder) { _, _, _ in
                            tapFeedback()
                            session.literal(String(character))
                        }
                    }
                    Group {
                        switch index {
                        case 0: functionKey("delete.left", label: "删除") { session.key(.backspace) }
                        case 1: functionKey("+", label: "加号", symbol: false) { session.literal("+") }
                        case 2: functionKey("−", label: "减号", symbol: false) { session.literal("-") }
                        default: functionKey("return", label: "回车") { session.key(.returnKey) }
                        }
                    }
                    .padding(.horizontal, 2.5)
                    .padding(.vertical, 3)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func keys(_ row: [Character], range: Range<Int>, index: Int, letters: Bool,
                      keyWidth: CGFloat? = nil, slides: Bool = false,
                      horizontalInset: CGFloat = 2.5, rowInset: CGFloat = 3, titleSize: CGFloat = 22) -> some View {
        ForEach(Array(range), id: \.self) { i in
            let letter = row[i]
            let usesPunctuationMapping = !letters && (session.page == .numbers || letter == "!" || letter == "?")
            let name = letters && session.uppercase ? String(letter).uppercased()
                : usesPunctuationMapping ? punctuationLabel(letter) : String(letter)
            let alternate = letters ? Array(KeyboardLayout.upper[index])[i] : nil
            let slideBounds = letters && slides ? (range.lowerBound - i)...(range.upperBound - i - 1) : nil
            TouchKey(title: name, alternate: alternate.map(punctuationLabel), holdLabel: letters ? String(letter).uppercased() : nil,
                     color: keyColor, border: keyBorder, slideBounds: slideBounds, highlighted: slidingKey == letter,
                     fadesOnRelease: slidingKey == nil, horizontalInset: horizontalInset, rowInset: rowInset,
                     titleSize: titleSize, preview: { offset in slidingKey = offset.map { row[i + $0] } }) { kind, fraction, offset in
                tapFeedback()
                guard letters else {
                    if usesPunctuationMapping, !letter.isNumber, !session.composition.english {
                        session.key(.punctuation(letter))
                    } else {
                        session.literal(String(letter))
                    }
                    return
                }
                if kind == .up, let alternate {
                    if alternate.isNumber || session.composition.english {
                        session.literal(String(alternate))
                    } else {
                        session.key(.punctuation(alternate))
                    }
                } else if kind == .held {
                    session.literal(String(letter).uppercased())
                } else if let offset {
                    session.letter(row[i + offset], neighbour: nil)
                } else {
                    let adjacent = fraction < 0.19 ? i - 1 : (fraction > 0.81 ? i + 1 : i)
                    let neighbour = range.contains(adjacent) && adjacent != i ? row[adjacent] : nil
                    session.letter(letter, neighbour: neighbour)
                }
            }
            .frame(width: keyWidth)
        }
    }

    private func punctuationLabel(_ character: Character) -> String {
        if session.composition.english { return String(character) }
        return session.composition.punctuationMark(character, preferences: store.preferences) ?? String(character)
    }

    private func toolbar(width: CGFloat, compact: Bool, rowInset: CGFloat) -> some View {
        HStack(spacing: compact ? 0 : 4) {
            if compact {
                let sideWidth = min(width * 0.24, voice == nil ? 112 : 90)
                pageKey(horizontalInset: KeyboardLayout.compactKeyInset, rowInset: rowInset).frame(width: sideWidth)
                spaceKey(horizontalInset: KeyboardLayout.compactKeyInset, rowInset: rowInset)
                if let voice {
                    VoiceHoldButton(active: recording, onHold: voice)
                        .frame(width: 38).padding(.vertical, rowInset)
                }
                if session.page == .emoji {
                    functionKey("delete.left", label: "删除", rowInset: rowInset) { session.key(.backspace) }
                        .frame(width: 40)
                }
                functionKey("return", label: "回车", horizontalInset: KeyboardLayout.compactKeyInset, rowInset: rowInset) {
                    session.key(.returnKey)
                }
                .frame(width: sideWidth)
            } else {
                pageModeKey.frame(width: 43)
                emojiKey.frame(width: 42)
                languageKey.frame(width: 40)
                spaceKey
                if let voice {
                    VoiceHoldButton(active: recording, onHold: voice).frame(width: 38)
                }
                if session.page == .emoji {
                    functionKey("delete.left", label: "删除") { session.key(.backspace) }.frame(width: 40)
                }
                functionKey("return", label: "回车") { session.key(.returnKey) }.frame(width: 68)
            }
        }
        .padding(.top, compact ? 0 : 4)
        .frame(height: compact ? 45 + 2 * rowInset : 44)
    }

    private var pageModeKey: some View { pageKey() }

    private func pageKey(horizontalInset: CGFloat = 0, rowInset: CGFloat = 0) -> some View {
        let textPage = session.page == .letters
        return functionKey(textPage ? "123" : "ABC", label: textPage ? "数字键盘" : "字母键盘", symbol: false,
                           horizontalInset: horizontalInset, rowInset: rowInset) {
            session.page = textPage ? .numbers : .letters
        }
    }

    private var emojiKey: some View { emojiKey(chrome: false) }

    private func emojiKey(chrome: Bool) -> some View {
        functionKey("face.smiling", label: session.page == .emoji ? "返回字母" : "表情", chrome: chrome) {
            session.page = session.page == .emoji ? .letters : .emoji
        }
    }

    private var languageKey: some View { languageKey(chrome: false) }

    private func languageKey(chrome: Bool) -> some View {
        functionKey(session.composition.english ? "英" : "中", label: "切换中英文", symbol: false, chrome: chrome) {
            session.toggleLanguage()
        }
        .accessibilityValue(session.composition.english ? "英文" : "中文")
    }

    private var spaceKey: some View { spaceKey(horizontalInset: 0, rowInset: 0) }

    private func spaceKey(horizontalInset: CGFloat, rowInset: CGFloat) -> some View {
        SpaceKey(color: keyColor, border: keyBorder, horizontalInset: horizontalInset, rowInset: rowInset,
                 tap: { tapFeedback(); session.key(.space) }, move: session.moveCursor)
    }

    private func rowModeKey(letters: Bool, horizontalInset: CGFloat = 0, rowInset: CGFloat = 3) -> some View {
        Group {
            if letters {
                let icon = session.shiftState == .locked ? "capslock.fill" : (session.uppercase ? "shift.fill" : "shift")
                functionKey(icon, label: "大写", horizontalInset: horizontalInset, rowInset: rowInset) { session.tapShift() }
                    .accessibilityValue(session.shiftState == .locked ? "大写锁定" : (session.uppercase ? "临时大写" : "关闭"))
            } else {
                let numbers = session.page == .numbers
                functionKey(numbers ? "#+=" : "123", label: numbers ? "更多符号" : "返回数字", symbol: false,
                            horizontalInset: horizontalInset, rowInset: rowInset) {
                    session.page = numbers ? .symbols : .numbers
                }
            }
        }
    }

    private func functionKey(_ title: String, label: String, symbol: Bool = true, chrome: Bool = false,
                             horizontalInset: CGFloat = 0, rowInset: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button {
            tapFeedback()
            action()
        } label: {
            Group {
                if symbol { Image(systemName: title) }
                else { Text(title).monospacedDigit() }
            }
            .font(.system(size: chrome || horizontalInset > 0 ? 16 : 13, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if !chrome { KeyCap(color: functionColor, border: keyBorder) }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyPressStyle(horizontalInset: horizontalInset, rowInset: rowInset))
        .accessibilityLabel(label)
    }
}

private struct ClipboardPasteButton: View {
    let insert: (String) -> Void
    @State private var hasText = false

    var body: some View {
        Group {
            if hasText {
                Button {
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    insert(text)
                } label: {
                    Label("粘贴", systemImage: "clipboard")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(.thinMaterial, in: Capsule())
                }
                .accessibilityLabel("粘贴剪贴板文字")
            }
        }
        .onAppear { hasText = UIPasteboard.general.hasStrings }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            hasText = UIPasteboard.general.hasStrings
        }
    }
}

private struct KeyCap: View {
    let color: Color
    let border: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyboardLayout.compactCornerRadius)
        shape.fill(color)
            .shadow(color: .black.opacity(0.38), radius: 0, x: 0, y: 1)
            .overlay { shape.strokeBorder(border, lineWidth: 0.5).allowsHitTesting(false) }
    }
}

struct KeyPressStyle: ButtonStyle {
    var horizontalInset: CGFloat = 0
    var rowInset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                KeyPressHighlight(pressed: configuration.isPressed)
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, rowInset)
            }
    }
}

private struct KeyPressHighlight: View {
    @Environment(\.colorScheme) private var colorScheme
    let pressed: Bool
    var fadesOnRelease = true

    var body: some View {
        RoundedRectangle(cornerRadius: KeyboardLayout.compactCornerRadius)
            .fill(Color.accentColor)
            .opacity(pressed ? (colorScheme == .dark ? 0.54 : 0.42) : 0)
            .animation(pressed || !fadesOnRelease ? nil : .easeOut(duration: 0.16), value: pressed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TouchKey: View {
    enum Kind { case tap, up, held }
    var title: String
    var alternate: String?
    var holdLabel: String?
    var color: Color
    var border: Color
    var slideBounds: ClosedRange<Int>?
    var highlighted = false
    var fadesOnRelease = true
    var horizontalInset: CGFloat = 2.5
    var rowInset: CGFloat = 3
    var titleSize: CGFloat = 22
    var preview: (Int?) -> Void = { _ in }
    var action: (Kind, CGFloat, Int?) -> Void
    @State private var start: Date?
    @GestureState private var tracking = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Text(title).font(.system(size: titleSize, weight: .regular))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let alternate {
                    Text(alternate).font(.system(size: 9)).foregroundStyle(.secondary)
                        .padding(.top, 2).padding(.trailing, 4)
                }
            }
            .background {
                KeyCap(color: color, border: border)
            }
            .overlay {
                KeyPressHighlight(pressed: slideBounds == nil ? tracking : highlighted,
                                  fadesOnRelease: fadesOnRelease)
            }
            .padding(.horizontal, horizontalInset).padding(.vertical, rowInset)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($tracking) { _, tracking, _ in tracking = true }
                .onChanged { value in
                    if start == nil { start = Date() }
                    if slideBounds != nil {
                        preview(projectedKey(value, width: geometry.size.width) ?? 0)
                    }
                }
                .onEnded { value in
                    let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0
                    let x = value.startLocation.x / max(1, geometry.size.width)
                    if let offset = projectedKey(value, width: geometry.size.width) {
                        action(.tap, x, offset)
                    } else if value.translation.height < -14 {
                        action(.up, x, nil)
                    }
                    else if abs(value.translation.width) < 21, value.translation.height < 20 {
                        action(elapsed >= 0.42 ? .held : .tap, x, nil)
                    }
                })
            .onChange(of: tracking) { _, active in
                if !active {
                    start = nil
                    if slideBounds != nil { preview(nil) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action(.tap, 0.5, nil) }
            .accessibilityAction(named: Text(alternate ?? holdLabel ?? title)) {
                action(alternate == nil ? .held : .up, 0.5, nil)
            }
        }
    }

    private func projectedKey(_ value: DragGesture.Value, width: CGFloat) -> Int? {
        guard let slideBounds, width > 0 else { return nil }
        let horizontal = abs(value.translation.width)
        guard horizontal >= 7, horizontal > abs(value.translation.height) * 1.15 else { return nil }
        let index = Int(floor(value.location.x / width))
        return min(slideBounds.upperBound, max(slideBounds.lowerBound, index))
    }
}

private struct SpaceKey: View {
    let color: Color
    let border: Color
    let horizontalInset: CGFloat
    let rowInset: CGFloat
    let tap: () -> Void
    let move: (Int) -> Void
    @State private var started: Date?
    @State private var origin: CGFloat?
    @State private var offset = 0
    @GestureState private var tracking = false

    var body: some View {
        Text(origin == nil ? " " : "←   →")
            .font(.footnote)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { KeyCap(color: color, border: border) }
            .overlay { KeyPressHighlight(pressed: tracking) }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, rowInset)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($tracking) { _, tracking, _ in tracking = true }
                .onChanged { value in
                    if started == nil { started = Date() }
                    let x = value.translation.width
                    if origin == nil, let started, Date().timeIntervalSince(started) >= 0.2, abs(x) >= 8 {
                        origin = x.sign == .minus ? min(-8, x + 6) : max(8, x - 6)
                    }
                    guard let origin else { return }
                    let next = Int(((x - origin) / 12).rounded(.towardZero))
                    if next != offset { move(next - offset); offset = next }
                }
                .onEnded { value in
                    if origin == nil, abs(value.translation.width) < 10, abs(value.translation.height) < 16 { tap() }
                    started = nil; origin = nil; offset = 0
                })
            .accessibilityLabel("空格")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .accessibilityAction(named: Text("光标左移")) { move(-1) }
            .accessibilityAction(named: Text("光标右移")) { move(1) }
    }
}

struct VoiceHoldButton: View {
    let active: Bool
    let onHold: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: active ? "waveform" : "mic")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? Color.red : Color.primary)
            .frame(minWidth: 37, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay { KeyPressHighlight(pressed: pressed) }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.18, perform: {}, onPressingChanged: { down in
                pressed = down
                onHold(down)
            })
            .accessibilityLabel("按住说话")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onHold(!active) }
    }
}
