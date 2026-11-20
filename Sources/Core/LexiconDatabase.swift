import Foundation
import SQLite3

final class LexiconDatabase: @unchecked Sendable {
    private let connection: OpaquePointer

    init?(_ url: URL) {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        guard Self.execute("PRAGMA cache_size = -512; PRAGMA mmap_size = 16777216", on: handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        connection = handle
        guard read("PRAGMA user_version", [], { sqlite3_column_int($0, 0) }) == [2] else { return nil }
    }

    deinit { sqlite3_close(connection) }

    func entries(for code: String) -> [Entry] {
        read("SELECT word, code, weight FROM entries WHERE code = ? ORDER BY position", [code], Self.entry)
    }

    func visitContinuations(for prefix: String, visit: (Entry) -> Bool) {
        query("SELECT word, code, weight FROM entries WHERE code > ? AND code < ? ORDER BY code, position",
              [prefix, prefix + "{"]) { visit(Self.entry($0)) }
    }

    func pinyinCandidates(for code: String) -> [Candidate] {
        read("SELECT word, hint FROM pinyin WHERE code = ? ORDER BY position", [code]) {
            Candidate(Self.string($0, 0), hint: Self.string($0, 1))
        }
    }

    func pinyinIndex() -> [String: [Candidate]] {
        var index: [String: [Candidate]] = [:]
        query("SELECT code, word, hint FROM pinyin ORDER BY code, position", []) { row in
            index[Self.string(row, 0), default: []].append(Candidate(Self.string(row, 1), hint: Self.string(row, 2)))
            return true
        }
        return index
    }

    func code(for word: String) -> String? {
        read("SELECT code FROM words WHERE word = ?", [word.precomposedStringWithCanonicalMapping]) {
            Self.string($0, 0)
        }.first
    }

    func stem(for word: String) -> String? {
        read("SELECT code FROM stems WHERE word = ?", [word.precomposedStringWithCanonicalMapping]) {
            Self.string($0, 0)
        }.first
    }

    private func query(_ sql: String, _ parameters: [String], _ visit: (OpaquePointer) -> Bool) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in parameters.enumerated() {
            guard Self.bind(value, to: statement, at: Int32(index + 1)) == SQLITE_OK else { return }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if !visit(statement) { break }
        }
    }

    private func read<T>(_ sql: String, _ parameters: [String], _ transform: (OpaquePointer) -> T) -> [T] {
        var rows: [T] = []
        query(sql, parameters) {
            rows.append(transform($0))
            return true
        }
        return rows
    }

    private static func entry(_ row: OpaquePointer) -> Entry {
        Entry(string(row, 0), string(row, 1), weight: Int(sqlite3_column_int64(row, 2)))
    }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func execute(_ sql: String, on db: OpaquePointer) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func bind(_ value: String, to statement: OpaquePointer, at position: Int32) -> Int32 {
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return sqlite3_bind_text(statement, position, value, -1, copy)
    }

    #if os(macOS)
    static func write(to url: URL, entries: [String: [Entry]], words: [String: String],
                      stems: [String: String], pinyin: [String: [Candidate]]) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(handle) }
        func checked(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
            guard result == expected else {
                throw NSError(domain: "SQLite", code: Int(result), userInfo: [
                    NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))
                ])
            }
        }
        func writeRows(_ sql: String, write: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            try checked(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
            guard let statement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            try write(statement)
        }
        try checked(execute("""
            PRAGMA user_version = 2;
            BEGIN;
            CREATE TABLE entries(code TEXT, position INTEGER, word TEXT NOT NULL, weight INTEGER NOT NULL,
                                 PRIMARY KEY(code, position)) WITHOUT ROWID;
            CREATE TABLE words(word TEXT PRIMARY KEY, code TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE stems(word TEXT PRIMARY KEY, code TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE pinyin(code TEXT, position INTEGER, word TEXT NOT NULL, hint TEXT NOT NULL,
                                PRIMARY KEY(code, position)) WITHOUT ROWID;
            """, on: handle))
        try writeRows("INSERT INTO entries VALUES(?, ?, ?, ?)") { statement in
            for code in entries.keys.sorted() {
                for (position, entry) in entries[code, default: []].enumerated() {
                    try checked(bind(code, to: statement, at: 1))
                    try checked(sqlite3_bind_int64(statement, 2, Int64(position)))
                    try checked(bind(entry.word, to: statement, at: 3))
                    try checked(sqlite3_bind_int64(statement, 4, Int64(entry.weight)))
                    try checked(sqlite3_step(statement), expected: SQLITE_DONE)
                    try checked(sqlite3_reset(statement))
                }
            }
        }
        for (table, codes) in [("words", words), ("stems", stems)] {
            try writeRows("INSERT INTO \(table) VALUES(?, ?)") { statement in
                for word in codes.keys.sorted() {
                    try checked(bind(word.precomposedStringWithCanonicalMapping, to: statement, at: 1))
                    try checked(bind(codes[word, default: ""], to: statement, at: 2))
                    try checked(sqlite3_step(statement), expected: SQLITE_DONE)
                    try checked(sqlite3_reset(statement))
                }
            }
        }
        try writeRows("INSERT INTO pinyin VALUES(?, ?, ?, ?)") { statement in
            for code in pinyin.keys.sorted() {
                for (position, candidate) in pinyin[code, default: []].enumerated() {
                    try checked(bind(code, to: statement, at: 1))
                    try checked(sqlite3_bind_int64(statement, 2, Int64(position)))
                    try checked(bind(candidate.word, to: statement, at: 3))
                    try checked(bind(candidate.hint, to: statement, at: 4))
                    try checked(sqlite3_step(statement), expected: SQLITE_DONE)
                    try checked(sqlite3_reset(statement))
                }
            }
        }
        try checked(execute("COMMIT; VACUUM", on: handle))
    }
    #endif
}
