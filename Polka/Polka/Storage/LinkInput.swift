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
}
