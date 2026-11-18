import CoreText
import SwiftUI

private struct EmojiEntry: Identifiable, Sendable {
    let group: String
    let glyph: String
    let name: String
    var id: String { glyph }
}

private enum EmojiCatalog {
    static let entries: [EmojiEntry] = {
        guard let url = Bundle.main.url(forResource: "Emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let attribute = NSAttributedString.Key(kCTFontAttributeName as String)
        return text.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let glyph = String(parts[1])
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [attribute: font]))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            guard runs.count == 1, let run = runs.first, CTRunGetGlyphCount(run) == 1 else { return nil }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { return nil }
            let actualFont = font as! CTFont
            guard (CTFontCopyPostScriptName(actualFont) as String).hasPrefix("AppleColorEmoji") else { return nil }
            var rendered = CGGlyph(0)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &rendered)
            guard rendered != 0 else { return nil }
            return EmojiEntry(group: String(parts[0]), glyph: glyph, name: String(parts[2]))
        }
    }()
}

struct EmojiPalette: View {
    let insert: (String) -> Void
    @State private var entries: [EmojiEntry] = []
    @State private var selected = "Smileys & Emotion"
    private let categories: [(String, String, String)] = [
        ("Smileys & Emotion", "😊", "表情"), ("People & Body", "👋", "人物"),
        ("Animals & Nature", "🐶", "动物与自然"), ("Food & Drink", "🍎", "食物"),
        ("Travel & Places", "🚙", "旅行"), ("Activities", "⚽️", "活动"),
        ("Objects", "💡", "物品"), ("Symbols", "❤️", "符号"), ("Flags", "🚩", "旗帜"),
        ("Component", "🎨", "肤色与发色")
    ]

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 1)], spacing: 2) {
                        ForEach(entries.filter { $0.group == selected }) { item in
                            Button { insert(item.glyph) } label: {
                                Text(item.glyph).font(.system(size: 26))
                                    .frame(maxWidth: .infinity, minHeight: 39)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .id(selected)
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(categories, id: \.0) { category in
                            Button { selected = category.0 } label: {
                                Text(category.1).frame(width: 34, height: 30)
                                    .background(selected == category.0 ? Color.accentColor.opacity(0.18) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(category.2)
                            .accessibilityAddTraits(selected == category.0 ? [.isSelected] : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { entries = await Task.detached(priority: .userInitiated) { EmojiCatalog.entries }.value }
    }
}
