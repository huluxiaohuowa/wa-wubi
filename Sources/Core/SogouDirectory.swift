import CoreFoundation
import Foundation

public struct SogouDictionary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public var page: URL { URL(string: "https://pinyin.sogou.com/dict/detail/index/" + id)! }

    public var downloads: [URL] {
        [
            "https://pinyin.sogou.com/d/dict/download_cell.php",
            "https://download.pinyin.sogou.com/dict/download_cell.php",
        ].compactMap { base in
            var parts = URLComponents(string: base)
            parts?.queryItems = [.init(name: "id", value: id), .init(name: "name", value: name)]
            return parts?.url
        }
    }
}

public enum SogouDirectory {
    public static let home = URL(string: "https://pinyin.sogou.com/dict/")!

    public static func search(_ input: String, page: Int = 1) -> URL? {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return home }
        guard term.count <= 80, (1...1000).contains(page) else { return nil }
        let rawEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let data = term.data(using: String.Encoding(rawValue: rawEncoding)) else { return nil }
        let encoded = data.map { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
        var parts = URLComponents(url: home, resolvingAgainstBaseURL: false)
        parts?.percentEncodedPath = "/dict/search/search_list/" + encoded + "/normal" + (page == 1 ? "" : "/\(page)")
        return parts?.url
    }

    public static func parse(_ html: String) -> [SogouDictionary] {
        let pattern = #"download_cell\.php\?id=([0-9]{1,10})(?:&|&amp;)name=([^&"'<>\r\n]+)"#
        guard let matcher = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found = Set<String>()
        return matcher.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let number = Range(match.range(at: 1), in: html), let title = Range(match.range(at: 2), in: html) else { return nil }
            let id = String(html[number])
            let raw = String(html[title])
            let name = (raw.removingPercentEncoding ?? raw)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200, found.insert(id).inserted else { return nil }
            return SogouDictionary(id: id, name: name)
        }
    }

    public static func hasNextPage(in html: String, after page: Int) -> Bool {
        html.contains("/normal/\(page + 1)\"") || html.contains("/normal/\(page + 1)'")
    }
}
