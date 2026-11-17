import SwiftUI
import WubiCore

struct PersonalWordEditor: View {
    private struct Row: Identifiable {
        var id = UUID()
        var word = ""
        var manualCode: String?
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedWord: UUID?
    @State private var rows: [Row]
    @State private var error = ""
    private let lexicon: Lexicon
    private let save: ([Entry]) -> Void

    init(entries: [Entry], lexicon: Lexicon, save: @escaping ([Entry]) -> Void) {
        self.lexicon = lexicon
        self.save = save
        let rows = entries.map { item in
            Row(word: item.word, manualCode: lexicon.fullCode(for: item.word) == item.code ? nil : item.code)
        }
        _rows = State(initialValue: rows.isEmpty ? [Row()] : rows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑用户词库").font(.title2.weight(.semibold))
            Text("输入词条后会自动填入编码。需要时可在右栏手动修改。")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("词条").frame(maxWidth: .infinity, alignment: .leading)
                Text("五笔编码").frame(width: 120, alignment: .leading)
                Color.clear.frame(width: 52, height: 1)
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($rows) { $row in
                        HStack(spacing: 12) {
                            TextField("输入词条", text: $row.word)
                                .focused($focusedWord, equals: row.id)
                                .onSubmit { append(after: row.id) }
                            TextField("手动填写", text: Binding(
                                get: { row.manualCode ?? computed(row.word) ?? "" },
                                set: { row.manualCode = $0.lowercased() }
                            ))
                            .monospaced().frame(width: 120)
                            .accessibilityLabel("五笔编码")
                            Button {
                                row.manualCode = nil
                            } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless)
                            .disabled(row.manualCode == nil)
                            .help("恢复自动编码")
                            Button {
                                let id = row.id
                                rows.removeAll { $0.id == id }
                                if rows.isEmpty { rows = [Row()] }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移除此词条")
                        }
                    }
                }.padding(2)
            }
            .frame(height: 240)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("添加词条") { append(after: rows.last?.id) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 530)
    }

    private func computed(_ word: String) -> String? {
        lexicon.fullCode(for: word.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func append(after id: UUID?) {
        let position = id.flatMap { id in rows.firstIndex { $0.id == id } } ?? max(0, rows.count - 1)
        if rows.indices.contains(position), rows[position].word.trimmingCharacters(in: .whitespaces).isEmpty {
            focusedWord = rows[position].id
            return
        }
        let row = Row()
        rows.insert(row, at: min(position + 1, rows.count))
        focusedWord = row.id
    }

    private func finish() {
        var entries: [Entry] = []
        for (index, row) in rows.enumerated() {
            let word = row.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let code = (row.manualCode ?? computed(word) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count <= 64, Entry.validCode(code) else {
                error = "第 \(index + 1) 行需要 1 至 4 位有效的五笔编码。"
                return
            }
            entries.append(Entry(word, code))
        }
        save(entries)
        dismiss()
    }
}
