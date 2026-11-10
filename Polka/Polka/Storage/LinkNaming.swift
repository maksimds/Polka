import Foundation

/// How a link is named on its tile: the site's name, then the page's address path,
/// like "GitHub/apple/swift". A home page is just the site's name.
enum LinkNaming {
    static func title(for url: URL, siteName: String?) -> String {
        guard url.host != nil else { return url.absoluteString }
        let site = siteName ?? nameFromAddress(url) ?? url.absoluteString
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? site : "\(site)/\(path)"
    }

    /// The site's name taken from its address, for sites that don't declare one:
    /// "www.linkedin.com" becomes "Linkedin" and "news.bbc.co.uk" becomes "Bbc".
    static func nameFromAddress(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var labels = host.split(separator: ".").map(String.init)
        // An IP address has no name to find.
        if labels.allSatisfy({ Int($0) != nil }) { return host }
        if labels.first == "www", labels.count > 2 { labels.removeFirst() }
        guard labels.count >= 2 else { return capitalizingFirstLetter(labels[0]) }

        var nameIndex = labels.count - 2
        // Country domains such as .co.uk keep the name one label further left.
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        if labels.count >= 3, labels[labels.count - 1].count == 2, secondLevel.contains(labels[labels.count - 2]) {
            nameIndex = labels.count - 3
        }
        return capitalizingFirstLetter(labels[nameIndex])
    }

    /// The name a page declares for its site in its `og:site_name` tag, if it has one.
    static func declaredSiteName(inHTML html: String) -> String? {
        let content = #"content\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        let property = #"(?:property|name)\s*=\s*["']og:site_name["']"#
        let patterns = [
            #"<meta\b[^>]*?\b"# + property + #"[^>]*?\b"# + content,
            #"<meta\b[^>]*?\b"# + content + #"[^>]*?\b"# + property,
        ]
        let fullRange = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: fullRange) else { continue }
            for group in 1...2 {
                guard let range = Range(match.range(at: group), in: html) else { continue }
                let name = decodingEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The handful of HTML entities that show up in site names. `&amp;` goes last so
    /// "&amp;lt;" becomes "&lt;" rather than "<".
    private static func decodingEntities(_ text: String) -> String {
        let entities = [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
                        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")]
        return entities.reduce(text) { result, entity in
            result.replacingOccurrences(of: entity.0, with: entity.1)
        }
    }
}
