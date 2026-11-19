import CoreText
import SwiftUI
import UIKit

private struct EmojiEntry: Equatable, Sendable {
    let group: String
    let glyph: String
    let name: String
}

private enum EmojiCatalog {
    private static let groups: [String: [EmojiEntry]] = {
        guard let url = Bundle.main.url(forResource: "Emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let entries: [EmojiEntry] = text.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return EmojiEntry(group: String(parts[0]), glyph: String(parts[1]), name: String(parts[2]))
        }
        return Dictionary(grouping: entries, by: \.group)
    }()

    static func supportedEntries(in group: String) -> [EmojiEntry] {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let attribute = NSAttributedString.Key(kCTFontAttributeName as String)
        var supported: [EmojiEntry] = []
        for entry in groups[group, default: []] {
            guard !Task.isCancelled else { break }
            let renders = autoreleasepool {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.glyph, attributes: [attribute: font]))
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                guard runs.count == 1, let run = runs.first, CTRunGetGlyphCount(run) == 1 else { return false }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let font = attributes[kCTFontAttributeName] else { return false }
                let actualFont = font as! CTFont
                guard (CTFontCopyPostScriptName(actualFont) as String).hasPrefix("AppleColorEmoji") else { return false }
                var rendered = CGGlyph(0)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &rendered)
                return rendered != 0
            }
            if renders { supported.append(entry) }
        }
        return supported
    }
}

struct EmojiPalette: View {
    let insert: (String) -> Void
    @State private var entries: [EmojiEntry]?
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
            if let entries {
                EmojiGrid(entries: entries, insert: insert)
                .id(selected)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(categories, id: \.0) { category in
                        Button {
                            guard selected != category.0 else { return }
                            entries = nil
                            selected = category.0
                        } label: {
                            Text(category.1).frame(width: 34, height: 30)
                                .background(selected == category.0 ? Color.accentColor.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(KeyPressStyle())
                        .accessibilityLabel(category.2)
                        .accessibilityAddTraits(selected == category.0 ? [.isSelected] : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .task(id: selected) {
            let group = selected
            let loading = Task.detached(priority: .userInitiated) { EmojiCatalog.supportedEntries(in: group) }
            let supported = await withTaskCancellationHandler {
                await loading.value
            } onCancel: {
                loading.cancel()
            }
            if !Task.isCancelled, selected == group { entries = supported }
        }
    }
}

private struct EmojiGrid: UIViewRepresentable {
    let entries: [EmojiEntry]
    let insert: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries, insert: insert) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 1
        layout.minimumLineSpacing = 2
        layout.sectionInset = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .clear
        grid.isPrefetchingEnabled = false
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        return grid
    }

    func updateUIView(_ grid: UICollectionView, context: Context) {
        context.coordinator.insert = insert
        if context.coordinator.entries != entries {
            context.coordinator.entries = entries
            grid.reloadData()
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var entries: [EmojiEntry]
        var insert: (String) -> Void

        init(entries: [EmojiEntry], insert: @escaping (String) -> Void) {
            self.entries = entries
            self.insert = insert
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            entries.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
            let entry = entries[indexPath.item]
            cell.label.text = entry.glyph
            cell.accessibilityLabel = entry.name
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            insert(entries[indexPath.item].glyph)
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = max(1, collectionView.bounds.width - 12)
            let columns = max(1, floor((width + 1) / 39))
            return CGSize(width: floor((width + 1) / columns - 1), height: 39)
        }
    }
}

private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 26)
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.frame = contentView.bounds
        label.isAccessibilityElement = false
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 8
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? tintColor.withAlphaComponent(0.42) : .clear }
    }
}
