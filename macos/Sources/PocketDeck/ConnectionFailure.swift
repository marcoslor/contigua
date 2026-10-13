// What the Mac tells the user when a connection fails, and whether retrying on
// its own can help.
//
// A failure is named by a reason: the phone's `error` code when it sent one
// before closing (docs/PROTOCOL.md "Error codes"), or a local reason such as
// "closed-by-peer" or "timeout". Transient reasons have no message and read as
// "Reconnecting…" while the session backs off. Pairing failures stop retrying,
// because each retry would make the phone ask for a new code.

enum ConnectionFailure {
    /// The phone stopped waiting for the pairing code (its 15 s window).
    static let pairingTimeout = "pairing-timeout"
    /// A cached address now answers as a different phone.
    static let identityMismatch = "identity-mismatch"

    /// The sentence shown for a failure; nil for transient failures.
    static func message(for reason: String) -> String? {
        switch reason {
        case "busy": return "Another Mac is connected"
        case "auth_failed": return "Pairing was removed on the phone, pair again"
        case "pair_denied": return "Pairing was denied"
        case "version": return "This phone runs an incompatible version of PocketDeck"
        case "protocol": return "The phone rejected a message from this Mac"
        case "no_stream": return "That window is no longer open on the phone"
        case "launch_failed": return "The app could not be started on the phone"
        case pairingTimeout: return "The phone stopped waiting for the code. Try again."
        case identityMismatch: return "Another phone is using the remembered address."
        default: return nil
        }
    }

    /// Whether the session should back off and connect again by itself.
    static func retriesAutomatically(_ reason: String) -> Bool {
        switch reason {
        case "pair_denied", "version", pairingTimeout, identityMismatch: return false
        default: return true
        }
    }
}
