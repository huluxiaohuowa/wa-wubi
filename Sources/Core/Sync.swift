import Foundation

public struct Revision: Codable, Comparable, Sendable {
    public var counter: UInt64
    public var device: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
    }
}

public struct Change: Codable, Sendable {
    public var revision: Revision
    public var value: Data?
}

public struct Snapshot: Codable, Sendable {
    public static let format = 1
    public var version = format
    public private(set) var values: [String: Change] = [:]

    public init() {}

    public mutating func set(_ key: String, to value: Data?, device: String) {
        let counter = values.values.map(\.revision.counter).max() ?? 0
        values[key] = Change(revision: Revision(counter: counter + 1, device: device), value: value)
    }

    @discardableResult
    public mutating func merge(_ other: Self) -> Bool {
        guard other.version == Self.format else { return false }
        var changed = false
        for (key, entry) in other.values {
            if let local = values[key], local.revision >= entry.revision { continue }
            values[key] = entry
            changed = true
        }
        return changed
    }
}
