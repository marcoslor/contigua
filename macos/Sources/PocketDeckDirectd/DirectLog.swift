#if POCKETDECK_DIRECT
import Foundation

/// States, counts, sizes, codes and durations only (docs/design/direct-link.md
/// §2.1, D6). Nothing from the app's traffic is ever printed.
enum DirectLog {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func line(_ message: String) {
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8))
    }
}
#endif
