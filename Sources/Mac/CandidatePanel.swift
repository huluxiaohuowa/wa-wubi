import AppKit
import SwiftUI
import WubiCore

struct CandidateStrip: View {
    let code: String
    let candidates: [Candidate]
    let current: Int
    let page: Int
    let pages: Int
    let preferences: Preferences
    var translations: [String]?
    var availableWidth: CGFloat = .infinity
    var forceVertical = false
    var choose: ((Int) -> Void)?
    var pin: ((Int) -> Void)?
    var hide: ((Int) -> Void)?
    var changePage: ((Int) -> Void)?
    var movable: Set<Int> = []
    var move: ((Int, Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragging: Int?
    @State private var dropTarget: Int?

    private var light: Bool {
        preferences.theme == .paper || (preferences.theme == .system && colorScheme == .light)
    }

    private var background: Color {
        if light { return Color(red: 0.965, green: 0.982, blue: 0.96) }
        if preferences.theme == .indigo { return Color(red: 0.12, green: 0.15, blue: 0.29) }
        return Color(red: 0.085, green: 0.16, blue: 0.145)
    }

    private var ink: Color { light ? Color(red: 0.07, green: 0.17, blue: 0.13) : .white }
    private var highlight: Color {
        if preferences.theme == .indigo { return Color(red: 0.79, green: 0.82, blue: 1) }
        return Color(red: 0.72, green: 0.91, blue: 0.80)
    }

    private var caption: Color { light ? Color(red: 0.13, green: 0.36, blue: 0.25) : highlight }

    var body: some View {
        strip(vertical: preferences.vertical || forceVertical)
    }

    private func strip(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) :
            AnyLayout(HStackLayout(alignment: translations == nil ? .center : .firstTextBaseline, spacing: 3))
        let showsCodes = candidates.contains { !$0.hint.isEmpty }
        return layout {
            Text(code)
                .font(.system(size: max(12, preferences.fontSize - 5), weight: .semibold, design: .monospaced))
                .foregroundStyle(caption)
                .padding(.horizontal, 7)
                .lineLimit(1)
            if candidates.isEmpty {
                if !code.contains(" ") && !code.contains("·") && !code.contains("…") {
                    Text("无候选").font(.system(size: 12)).foregroundStyle(ink.opacity(0.68))
                }
            } else {
                ForEach(candidates.indices, id: \.self) { index in
                    let button = Button {
                        if dragging == nil { choose?(index) }
                    } label: {
                        candidateLabel(index, vertical: vertical, showsCodes: showsCodes)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .foregroundStyle(index == current ? Color.black.opacity(0.86) : ink)
                        .background(index == current ? highlight : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .overlay {
                            if dropTarget == index && dragging != index {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(caption, lineWidth: 1.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index + 1) \(candidates[index].word)")
                    .accessibilityValue([candidates[index].hint, translation(at: index)]
                        .filter { !$0.isEmpty }.joined(separator: "，"))
                    .contextMenu {
                        if !candidates[index].isCloud {
                            if let pin { Button("移到首位") { pin(index) } }
                            if let hide { Button("隐藏候选") { hide(index) } }
                        }
                    }
                    if movable.contains(index) {
                        button.background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: CandidateFrames.self,
                                                       value: [index: geometry.frame(in: .named("candidates"))])
                            }
                        }
                        .simultaneousGesture(reorderGesture(from: index))
                    } else {
                        button
                    }
                }
                if pages > 1 {
                    HStack(spacing: 4) {
                        Button { changePage?(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0).accessibilityLabel("上一页")
                        Text("\(page + 1)/\(pages)").monospacedDigit()
                        Button { changePage?(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page + 1 == pages).accessibilityLabel("下一页")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(caption)
                    .padding(.horizontal, 5)
                }
            }
        }
        .coordinateSpace(name: "candidates")
        .onPreferenceChange(CandidateFrames.self) { frames = $0 }
        .padding(6)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(background.opacity(preferences.opacity))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.18)) }
        }
    }

    private func translation(at index: Int) -> String {
        guard let translations, translations.indices.contains(index) else { return "" }
        return translations[index]
    }

    private func candidateLabel(_ index: Int, vertical: Bool, showsCodes: Bool) -> some View {
        let candidate = candidates[index]
        let number = Text("\(index + 1)").font(.system(size: 10, weight: .medium, design: .monospaced))
        let word = Text(CandidateFont.label(candidate.word, size: preferences.fontSize))
        let code = Text(candidate.hint).font(.system(size: 10, design: .monospaced)).lineLimit(1)
        let translation = translation(at: index)
        let definition = Text(translation.isEmpty ? " " : translation)
            .font(.system(size: max(11, preferences.fontSize * 0.58)))
            .opacity(0.78)
        return Group {
            if vertical {
                HStack(spacing: 8) {
                    number.frame(width: 12, alignment: .leading)
                    word
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: min(220, max(1, availableWidth - 242)), alignment: .leading)
                        .layoutPriority(1)
                    if showsCodes {
                        code.frame(width: 40, alignment: .leading)
                    }
                    if translations != nil {
                        definition
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .frame(width: 128, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    number
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            word.lineLimit(1).fixedSize()
                            if !candidate.hint.isEmpty { code }
                        }
                        if translations != nil {
                            definition.lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func reorderGesture(from source: Int) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("candidates"))
            .onChanged { value in
                dragging = source
                dropTarget = frames.first { $0.value.contains(value.location) }?.key
            }
            .onEnded { value in
                if let target = frames.first(where: { $0.value.contains(value.location) })?.key, target != source {
                    move?(source, target)
                }
                dropTarget = nil
                DispatchQueue.main.async { dragging = nil }
            }
    }
}

private struct CandidateFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()
    weak var owner: InputController?

    private init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func render(_ view: CandidateStrip, at caret: CGRect, for owner: InputController) {
        self.owner = owner
        let mouse = NSEvent.mouseLocation
        let anchor = caret.isEmpty ? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1) : caret
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY))
        }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 7, dy: 7)
        var view = view
        view.availableWidth = bounds.width
        let host = NSHostingView(rootView: view)
        if #available(macOS 13, *) { host.sizingOptions = [.intrinsicContentSize] }
        contentView = host
        var size = host.fittingSize
        if !view.preferences.vertical && size.width > bounds.width {
            view.forceVertical = true
            host.rootView = view
            size = host.fittingSize
        }
        let below = anchor.minY - size.height - 5
        let y = below < bounds.minY ? min(bounds.maxY - size.height, anchor.maxY + 5) : below
        let x = max(bounds.minX, min(anchor.minX, bounds.maxX - size.width))
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        orderFrontRegardless()
    }

    func hide(for controller: InputController) {
        guard owner === controller else { return }
        orderOut(nil)
        owner = nil
    }
}
