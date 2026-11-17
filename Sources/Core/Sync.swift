import Foundation

public enum CloudResolution: String, CaseIterable, Identifiable, Sendable {
    case newest, local, cloud, replaceWithCloud
    public var id: Self { self }
}

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
    public var modifiedAt: Date?

    func precedes(_ other: Self) -> Bool {
        let first = modifiedAt ?? .distantPast
        let second = other.modifiedAt ?? .distantPast
        return first == second ? revision < other.revision : first < second
    }
}

public struct Snapshot: Codable, Sendable {
    public static let format = 1
    public var version = format
    public private(set) var values: [String: Change] = [:]

    public init() {}

    public mutating func set(_ key: String, to value: Data?, device: String, at date: Date = Date()) {
        let counter = values.values.map(\.revision.counter).max() ?? 0
        let previous = values[key]?.modifiedAt
        let timestamp = previous.map { max(date, $0) } ?? date
        values[key] = Change(revision: Revision(counter: counter + 1, device: device), value: value, modifiedAt: timestamp)
    }

    @discardableResult
    public mutating func merge(_ other: Self) -> Bool {
        guard other.version == Self.format else { return false }
        var changed = false
        for (key, entry) in other.values {
            if let local = values[key], !local.precedes(entry) { continue }
            values[key] = entry
            changed = true
        }
        return changed
    }

    public func resolved(with remote: Self, using policy: CloudResolution, device: String) -> Self {
        if policy == .replaceWithCloud { return remote }
        var result = self
        result.merge(remote)
        switch policy {
        case .local, .cloud:
            let preferred = policy == .local ? self : remote
            for (key, entry) in preferred.values where result.values[key]?.value != entry.value {
                result.set(key, to: entry.value, device: device)
            }
        case .newest, .replaceWithCloud:
            break
        }
        return result
    }
}
