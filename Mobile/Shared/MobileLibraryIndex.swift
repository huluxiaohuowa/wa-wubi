import Foundation
import SQLite3
import WubiCore

/// An extension-local index. The synced snapshot remains the source of truth.
final class MobileLibraryIndex: @unchecked Sendable {
    private let handle: OpaquePointer
    private let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
        url = directory.appendingPathComponent("wa-library-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database,
                                     SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw CocoaError(.fileWriteUnknown)
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: url)
    }

    func build(personal: [Entry], groups: [Data]) throws {
        // This disposable file is published only after the build has finished.
        // Keep page caches small and let SQLite spill sorting to disk.
        try execute("""
            PRAGMA journal_mode = OFF;
            PRAGMA cache_size = -512;
            PRAGMA temp_store = FILE;
            BEGIN;
            CREATE TABLE words(word TEXT PRIMARY KEY, code TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE entries(code TEXT NOT NULL, word TEXT NOT NULL, weight INTEGER NOT NULL);
            """)
        let remember = try prepare("INSERT OR REPLACE INTO words VALUES(?1, ?2)")
        defer { sqlite3_finalize(remember) }
        let rememberImported = try prepare("INSERT OR IGNORE INTO words VALUES(?1, ?2)")
        defer { sqlite3_finalize(rememberImported) }
        let append = try prepare("INSERT INTO entries SELECT code, ?3, ?2 FROM words WHERE word = ?1")
        defer { sqlite3_finalize(append) }
        for entry in personal {
            try run(remember, entry.word.precomposedStringWithCanonicalMapping, entry.code)
        }
        let decoder = JSONDecoder()
        for data in groups {
            try autoreleasepool {
                guard let group = try? decoder.decode(WordGroup.self, from: data) else { return }
                for entry in group.entries {
                    let wordKey = entry.word.precomposedStringWithCanonicalMapping
                    try run(rememberImported, wordKey, entry.code)
                    try bind(wordKey, to: append, index: 1)
                    try check(sqlite3_bind_int64(append, 2, Int64(entry.weight)))
                    try bind(entry.word, to: append, index: 3)
                    try check(sqlite3_step(append), expected: SQLITE_DONE)
                    try check(sqlite3_reset(append))
                }
            }
        }
        try execute("""
            CREATE INDEX lookup ON entries(code, weight DESC);
            COMMIT;
            """)
    }

    func entries(for code: String) -> [Entry] {
        select("SELECT word, weight FROM entries WHERE code = ?1 ORDER BY weight DESC, rowid", code) { row in
            Entry(Self.string(row, 0), code, weight: Int(sqlite3_column_int64(row, 1)))
        }
    }

    func contains(_ word: String) -> Bool {
        !select("SELECT 1 FROM words WHERE word = ?1", word.precomposedStringWithCanonicalMapping) { _ in true }.isEmpty
    }

    private func select<Value>(_ sql: String, _ key: String, _ transform: (OpaquePointer) -> Value) -> [Value] {
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        guard (try? bind(key, to: statement, index: 1)) != nil else { return [] }
        var result: [Value] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(transform(statement)) }
        return result
    }

    private func run(_ statement: OpaquePointer, _ word: String, _ code: String) throws {
        try bind(word, to: statement, index: 1)
        try bind(code, to: statement, index: 2)
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
        try check(sqlite3_reset(statement))
    }

    private func bind(_ text: String, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(text.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient)
        })
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw CocoaError(.fileReadUnknown) }
        return statement
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func string(_ row: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(row, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }
}
