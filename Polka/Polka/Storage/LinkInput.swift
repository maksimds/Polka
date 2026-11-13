import Foundation

/// Turns what was typed into the shelf's link field into a web address.
enum LinkInput {
    /// The web address `text` stands for, or nil if it isn't one.
    ///
    /// Without a scheme it's taken as https, so "example.com" works, and it then needs
    /// a dot in its host (or to be "localhost") to count as an address rather than a
    /// stray word. With a scheme, only http and https are accepted. The scheme and host
    /// are lowercased and an empty path becomes "/", the way browsers write addresses,
    /// so a typed link matches the same page dragged in from a browser.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        // "mailto:" or "https://" has a scheme; "localhost:3000" is a host and a port.
        let hasScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:(?!\d)"#,
                                      options: .regularExpression) != nil
        guard var components = URLComponents(string: hasScheme ? trimmed : "https://" + trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        if !hasScheme {
            let looksLikeAHost = host == "localhost"
                || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix("."))
            guard looksLikeAHost else { return nil }
        }

        components.scheme = scheme
        components.host = host
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    /// The web address that pasted or dropped text is, if all it holds is one address
    /// written out in full, with http or https. Anything less stays text: unlike in the
    /// link field, "notes.txt" or "example.com" in a document is more likely a name or
    /// a word than a link.
    static func link(inText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return url(from: text)
    }

    /// True for an http or https address with a host: the only links Polka stores,
    /// opens or looks up, typed or dropped. Any other address (`smb:`, `vnc:`, an
    /// app's own scheme) would be handed to whatever app handles it, without the
    /// "Allow this page to open…?" question a browser asks first.
    static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
