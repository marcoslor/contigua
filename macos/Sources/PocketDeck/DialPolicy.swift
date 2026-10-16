// Which peers a run may dial on its own.
//
// `default` is the person's own app: discovery is theirs, so it may connect to
// a phone found over Bonjour. Any other profile is a separate test/development
// copy on a Mac that shares its LAN with real phones; one such run dialed a
// real phone it had found over Bonjour and opened pairing screens on it. So a
// non-default profile dials only what it was told to (`--connect host:port`,
// the harness's fakephone or emulator) or a cached address from its own
// earlier session — never a discovered phone.

import Foundation

enum DialPolicy {
    /// True when automatic attempts (reconnects and QR probes) may use
    /// Bonjour-discovered phones.
    static func mayDialDiscovered(_ profile: Profile) -> Bool {
        profile.isDefault
    }
}
