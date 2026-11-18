public struct WordGroup: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var entries: [Entry]
    public var version: String?

    public init(id: String, name: String, entries: [Entry], version: String? = nil) {
        self.id = id
        self.name = name
        self.entries = entries
        self.version = version
    }
}
