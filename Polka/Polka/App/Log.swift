import OSLog

/// One logger per architecture layer.
/// View in Console.app: filter by subsystem "com.maksimds.Polka".
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.maksimds.Polka"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let drop = Logger(subsystem: subsystem, category: "drop")
}
