import Foundation
import OSLog

/// One logger per architecture layer.
/// View in Console.app: filter by subsystem "com.maksimds.Polka".
///
/// What's yours stays private: file and item names, paths, web addresses and site
/// names, other apps' names, and error messages, which macOS words with the file's
/// name in them. The log shows `<private>` there. Any admin on the Mac can read the
/// public parts, and they go into diagnostic reports, so only Polka's own workings
/// are public: counts, states, pasteboard types, link schemes, and each error's
/// domain and code (`logCode`), which is enough to tell what went wrong.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.maksimds.Polka"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let drop = Logger(subsystem: subsystem, category: "drop")
    static let storage = Logger(subsystem: subsystem, category: "storage")
}

extension Error {
    /// The error's domain and code, like "NSCocoaErrorDomain 513", safe to log publicly.
    var logCode: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
