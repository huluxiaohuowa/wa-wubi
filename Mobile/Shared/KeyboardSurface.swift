import CoreText
import SwiftUI
import UIKit
import WubiCore

enum KeyboardLayout {
    static let wideWidth: CGFloat = 580
    static let dockedHeight: CGFloat = 278
    static let topPadding: CGFloat = 3
    static let bottomPadding: CGFloat = 4
    static let phoneBottomPadding: CGFloat = 1

    @MainActor static func usesPhoneInsets(width: CGFloat, systemBackdrop: Bool) -> Bool {
        systemBackdrop && width < wideWidth && UIDevice.current.userInterfaceIdiom == .phone
    }

    static let compactKeyInset: CGFloat = 2
    static let compactVerticalKeyInset: CGFloat = 3.5
    static let compactCornerRadius: CGFloat = 7
    static func candidateFontSize(_ size: Double) -> CGFloat { min(31, max(17, size + 3)) }
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
    var dockedHeight: CGFloat?
    var usesSystemBackdrop = false
    var onDismissKeyboard: (() -> Void)?
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
            // The host can propose zero width while reconnecting the extension.
            let width = max(2, geometry.size.width)
            let wide = width >= KeyboardLayout.wideWidth
            let phoneInsets = KeyboardLayout.usesPhoneInsets(width: width, systemBackdrop: usesSystemBackdrop)
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
                candidateBar(wide: wide, showsBackground: floating || !usesSystemBackdrop)
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
            .padding(.top, phoneInsets ? 0 : KeyboardLayout.topPadding)
            .padding(.bottom, phoneInsets ? KeyboardLayout.phoneBottomPadding : KeyboardLayout.bottomPadding)
            .frame(width: panelWidth, height: panelHeight)
            .background {
                if floating || !usesSystemBackdrop {
                    keyboardBackdrop(floating: floating)
                }
            }
            .overlayPreferenceValue(LetterKeyBounds.self) { anchor in
                letterPreview(at: anchor)
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

    private func letterPreview(at anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            if let anchor, let letter = slidingKey {
                let bounds = geometry[anchor]
                let width = max(48, bounds.width + 8)
                let x = min(geometry.size.width - width / 2, max(width / 2, bounds.midX))
                let y = max(25, bounds.minY - 20)
                Text(session.uppercase ? String(letter).uppercased() : String(letter))
                    .font(.system(size: 32, weight: .medium))
                    .frame(width: width, height: 46)
                    .background(keyColor, in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11).strokeBorder(keyBorder)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
                    .position(x: x, y: y)
                    .transaction { $0.animation = nil }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    private func candidateBar(wide: Bool, showsBackground: Bool) -> some View {
        let c = session.composition
        return HStack(spacing: 5) {
            if session.showGlobe { globe().frame(width: 40, height: 40) }
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
            if wide {
                functionKey(session.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                            label: session.compact ? "恢复大键盘" : "缩成手机键盘") { session.compact.toggle() }
                    .frame(width: 38, height: 36)
            }
            if let onDismissKeyboard {
                Divider().frame(height: 24).accessibilityHidden(true)
                Button(action: onDismissKeyboard) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 43)
                        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("收起键盘")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .frame(height: 43)
        .background(Color(uiColor: .secondarySystemGroupedBackground)
            .opacity(showsBackground && !c.code.isEmpty ? store.preferences.opacity * 0.55 : 0),
                    in: UnevenRoundedRectangle(topLeadingRadius: 19, bottomLeadingRadius: 9,
                                               bottomTrailingRadius: 9, topTrailingRadius: 19))
    }

    @ViewBuilder private func candidateScroll(_ composition: Composition) -> some View {
        let scroll = ScrollView(.horizontal) {
            HStack(spacing: 0) { candidateItems(composition) }
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
                            .font(.system(size: KeyboardLayout.candidateFontSize(store.preferences.fontSize), weight: .medium))
                    } else {
                        Text(missing.map { "U+" + String($0, radix: 16, uppercase: true) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .accessibilityLabel("系统字体缺字，字符编码 " + missing.map { String($0, radix: 16, uppercase: true) }.joined(separator: "、"))
                    }
                    if !item.hint.isEmpty { Text(item.hint).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 43)
                .contentShape(Rectangle())
                .foregroundStyle(i == c.selected ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if item.isDictionaryEditable {
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
            Text("无法读取 86 五笔码表").foregroundStyle(.secondary).font(.footnote)
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
                let edgeWidth = compact ? unit * (letters ? 1.5 : 1.22) : 54
                let capInset = compact ? min(rowInset, KeyboardLayout.compactVerticalKeyInset) : rowInset
                let horizontalInset = compact ? KeyboardLayout.compactKeyInset : 2.5
                HStack(spacing: 0) {
                    if index == 2 {
                        rowModeKey(letters: letters, horizontalInset: horizontalInset, rowInset: capInset)
                            .frame(width: edgeWidth)
                    }
                    if compact && letters {
                        compactLetterRow(row, index: index, unit: unit, rowInset: capInset)
                    } else {
                        keys(row, range: row.indices, index: index, letters: letters,
                             horizontalInset: horizontalInset, rowInset: capInset, titleSize: compact ? 24 : 22)
                    }
                    if index == 2 {
                        functionKey("delete.left", label: "删除", horizontalInset: horizontalInset, rowInset: capInset) {
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

    private func compactLetterRow(_ row: [Character], index: Int, unit: CGFloat, rowInset: CGFloat) -> some View {
        let alternates = Array(KeyboardLayout.upper[index])
        return HStack(spacing: 0) {
            ForEach(row.indices, id: \.self) { i in
                let letter = row[i]
                let alternate = alternates[i]
                let title = session.uppercase ? String(letter).uppercased() : String(letter)
                let highlighted = slidingKey == letter
                TouchKey(title: title, alternate: punctuationLabel(alternate), color: keyColor, border: keyBorder,
                         highlighted: highlighted, fadesOnRelease: slidingKey == nil,
                         horizontalInset: KeyboardLayout.compactKeyInset, rowInset: rowInset,
                         titleSize: 24, handlesTouch: false) { kind, fraction in
                    sendLetter(row, at: i, in: row.indices, alternate: alternate, kind: kind, fraction: fraction)
                }
                .frame(width: unit)
                .anchorPreference(key: LetterKeyBounds.self, value: .bounds) { highlighted ? $0 : nil }
            }
        }
        .overlay {
            LetterRowTouch(keyCount: row.count, slides: store.slideCorrection) { target in
                let letter = target.map { row[$0] }
                if slidingKey != letter { slidingKey = letter }
            } action: { kind, origin, fraction, target in
                sendLetter(row, at: target ?? origin, in: row.indices, alternate: alternates[origin],
                           kind: kind, fraction: target == nil ? fraction : 0.5)
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
                        TouchKey(title: String(character), color: keyColor, border: keyBorder) { _, _ in
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
                      keyWidth: CGFloat? = nil,
                      horizontalInset: CGFloat = 2.5, rowInset: CGFloat = 3, titleSize: CGFloat = 22) -> some View {
        ForEach(Array(range), id: \.self) { i in
            let letter = row[i]
            let usesPunctuationMapping = !letters && (session.page == .numbers || letter == "!" || letter == "?")
            let name = letters && session.uppercase ? String(letter).uppercased()
                : usesPunctuationMapping ? punctuationLabel(letter) : String(letter)
            let alternate = letters ? Array(KeyboardLayout.upper[index])[i] : nil
            TouchKey(title: name, alternate: alternate.map(punctuationLabel), holdLabel: letters ? String(letter).uppercased() : nil,
                     color: keyColor, border: keyBorder, horizontalInset: horizontalInset, rowInset: rowInset,
                     titleSize: titleSize) { kind, fraction in
                if let alternate {
                    sendLetter(row, at: i, in: range, alternate: alternate, kind: kind, fraction: fraction)
                    return
                }
                tapFeedback()
                if usesPunctuationMapping, !letter.isNumber, !session.composition.english {
                    session.key(.punctuation(letter))
                } else {
                    session.literal(String(letter))
                }
            }
            .frame(width: keyWidth)
        }
    }

    private func sendLetter(_ row: [Character], at index: Int, in range: Range<Int>, alternate: Character,
                            kind: TouchKey.Kind, fraction: CGFloat) {
        tapFeedback()
        switch kind {
        case .up:
            if alternate.isNumber || session.composition.english { session.literal(String(alternate)) }
            else { session.key(.punctuation(alternate)) }
        case .held:
            session.literal(String(row[index]).uppercased())
        case .tap:
            let adjacent = fraction < 0.19 ? index - 1 : (fraction > 0.81 ? index + 1 : index)
            let neighbour = range.contains(adjacent) && adjacent != index ? row[adjacent] : nil
            session.letter(row[index], neighbour: neighbour)
        }
    }

    private func punctuationLabel(_ character: Character) -> String {
        if session.composition.english { return String(character) }
        return session.composition.punctuationMark(character, preferences: store.preferences) ?? String(character)
    }

    private func toolbar(width: CGFloat, compact: Bool, rowInset: CGFloat) -> some View {
        HStack(spacing: compact ? 0 : 4) {
            if compact {
                let inset = KeyboardLayout.compactKeyInset
                let sideWidth = min(width * 0.15, 64)
                let utilityWidth = min(width * 0.11, 46)
                pageKey(horizontalInset: inset, rowInset: rowInset).frame(width: sideWidth)
                languageKey(horizontalInset: inset, rowInset: rowInset).frame(width: utilityWidth)
                spaceKey(horizontalInset: inset, rowInset: rowInset)
                emojiKey(horizontalInset: inset, rowInset: rowInset).frame(width: utilityWidth)
                if let voice {
                    VoiceHoldButton(active: recording, onHold: voice)
                        .frame(width: 38).padding(.vertical, rowInset)
                }
                if session.page == .emoji {
                    functionKey("delete.left", label: "删除", rowInset: rowInset) { session.key(.backspace) }
                        .frame(width: 40)
                }
                functionKey("return", label: "回车", horizontalInset: inset, rowInset: rowInset) {
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

    private var emojiKey: some View { emojiKey(horizontalInset: 0, rowInset: 0) }

    private func emojiKey(horizontalInset: CGFloat, rowInset: CGFloat) -> some View {
        functionKey("face.smiling", label: session.page == .emoji ? "返回字母" : "表情",
                    horizontalInset: horizontalInset, rowInset: rowInset) {
            session.page = session.page == .emoji ? .letters : .emoji
        }
    }

    private var languageKey: some View { languageKey(horizontalInset: 0, rowInset: 0) }

    private func languageKey(horizontalInset: CGFloat, rowInset: CGFloat) -> some View {
        functionKey(session.composition.english ? "英" : "中", label: "切换中英文", symbol: false,
                    horizontalInset: horizontalInset, rowInset: rowInset) {
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

    private func functionKey(_ title: String, label: String, symbol: Bool = true,
                             horizontalInset: CGFloat = 0, rowInset: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button {
            tapFeedback()
            action()
        } label: {
            Group {
                if symbol { Image(systemName: title) }
                else { Text(title).monospacedDigit() }
            }
            .font(.system(size: horizontalInset > 0 ? 16 : 13, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { KeyCap(color: functionColor, border: keyBorder) }
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

private struct LetterKeyBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

private struct LetterRowTouch: UIViewRepresentable {
    let keyCount: Int
    let slides: Bool
    let preview: (Int?) -> Void
    let action: (TouchKey.Kind, Int, CGFloat, Int?) -> Void

    func makeUIView(context: Context) -> LetterRowTouchView {
        let view = LetterRowTouchView()
        view.isOpaque = false
        // A fully transparent row can leave keycap gaps untouchable in the hosted keyboard.
        view.backgroundColor = UIColor(white: 0, alpha: 0.02)
        return view
    }

    func updateUIView(_ view: LetterRowTouchView, context: Context) {
        view.keyCount = keyCount
        view.slides = slides
        view.preview = preview
        view.action = action
    }
}

private final class LetterRowTouchView: UIView {
    var keyCount = 1
    var slides = false
    var preview: (Int?) -> Void = { _ in }
    var action: (TouchKey.Kind, Int, CGFloat, Int?) -> Void = { _, _, _, _ in }
    private var firstTouch: UITouch?
    private var start = CGPoint.zero
    private var startedAt: TimeInterval = 0
    private var unit: CGFloat { max(1, bounds.width / CGFloat(keyCount)) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard firstTouch == nil, let touch = touches.first else { return }
        firstTouch = touch
        start = touch.location(in: self)
        startedAt = touch.timestamp
        preview(key(at: start.x))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = firstTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        preview(projectedKey(at: point) ?? (point.y - start.y < -14 ? nil : key(at: start.x)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = firstTouch, touches.contains(touch) else { return }
        firstTouch = nil
        preview(nil)
        let point = touch.location(in: self)
        let origin = key(at: start.x)
        let fraction = start.x / unit - CGFloat(origin)
        if let target = projectedKey(at: point) {
            action(.tap, origin, fraction, target)
        } else if point.y - start.y < -14 {
            action(.up, origin, fraction, nil)
        } else if abs(point.x - start.x) < 21, point.y - start.y < 20 {
            let held = touch.timestamp - startedAt >= 0.42
            action(held ? .held : .tap, origin, fraction, nil)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = firstTouch, touches.contains(touch) else { return }
        firstTouch = nil
        preview(nil)
    }

    private func key(at x: CGFloat) -> Int {
        min(keyCount - 1, max(0, Int(floor(x / unit))))
    }

    private func projectedKey(at point: CGPoint) -> Int? {
        let horizontal = abs(point.x - start.x)
        guard slides, horizontal >= 7, horizontal > abs(point.y - start.y) * 1.15 else { return nil }
        return key(at: point.x)
    }
}

private struct TouchKey: View {
    enum Kind { case tap, up, held }
    var title: String
    var alternate: String?
    var holdLabel: String?
    var color: Color
    var border: Color
    var highlighted = false
    var fadesOnRelease = true
    var horizontalInset: CGFloat = 2.5
    var rowInset: CGFloat = 3
    var titleSize: CGFloat = 22
    var handlesTouch = true
    var action: (Kind, CGFloat) -> Void
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
                KeyPressHighlight(pressed: handlesTouch ? tracking : highlighted,
                                  fadesOnRelease: fadesOnRelease)
            }
            .padding(.horizontal, horizontalInset).padding(.vertical, rowInset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
                if handlesTouch {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($tracking) { _, tracking, _ in tracking = true }
                            .onChanged { value in
                                if start == nil { start = Date() }
                            }
                            .onEnded { value in
                                let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0
                                let x = value.startLocation.x / max(1, geometry.size.width)
                                if value.translation.height < -14 {
                                    action(.up, x)
                                } else if abs(value.translation.width) < 21, value.translation.height < 20 {
                                    action(elapsed >= 0.42 ? .held : .tap, x)
                                }
                            })
                }
            }
            .onChange(of: tracking) { _, active in
                if !active { start = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action(.tap, 0.5) }
            .accessibilityAction(named: Text(alternate ?? holdLabel ?? title)) {
                action(alternate == nil ? .held : .up, 0.5)
            }
        }
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
