// What the Mac tells the user when a connection fails, and whether retrying on
// its own can help.
//
// A failure is named by a reason: the phone's `error` code when it sent one
// before closing (docs/PROTOCOL.md "Error codes"), or a local reason such as
// "closed-by-peer" or "timeout". Transient reasons have no message and read as
// "Reconnecting…" while the session backs off. Pairing failures stop retrying,
// because each retry would make the phone ask for a new code.

enum ConnectionFailure {
    /// A cached address now answers as a different phone.
    static let identityMismatch = "identity-mismatch"

    /// The sentence shown for a failure; nil for transient failures.
    /// `phoneName` is what the person calls the phone (its nickname or its own
    /// name); the two gate refusals name it because the phone never got as far
    /// as a `welcome`.
    static func message(for reason: String, phoneName: String = "your phone") -> String? {
        switch reason {
        case "connections_off": return "Connections are turned off on \(phoneName)."
        case "pairing_off": return "\(phoneName) isn't accepting new pairings."
        case "busy": return "Another Mac is connected"
        case "pin-mismatch", "bad_pin":
            return "This phone's identity changed. Pair again."
        case "no-pin":
            return "Pairing was removed on the phone, pair again"
        case "forgotten":
            return "This phone no longer trusts this Mac. Pair again."
        case "pair_denied": return "Pairing was denied"
        case "version": return "This phone runs an incompatible version of PocketDeck"
        case "protocol": return "The phone rejected a message from this Mac"
        case "no_stream": return "That window is no longer open on the phone"
        case "launch_failed": return "The app could not be started on the phone"
        case "pair_timeout": return "Nobody tapped Allow on the phone in time. Try again."
        case "pair_exporter":
            return "This phone's Android version can't make a secure pairing code. Update Android or PocketDeck."
        case identityMismatch: return "Another phone is using the remembered address."
        default: return nil
        }
    }

    /// Whether the session should back off and connect again by itself.
    static func retriesAutomatically(_ reason: String) -> Bool {
        switch reason {
        case "pair_denied", "pair_timeout", "pair_cooldown", "pair_exporter", "version",
             identityMismatch, "pin-mismatch", "bad_pin", "not_paired", "forgotten": return false
        default: return true
        }
    }
}
