// Where the session's own pin stands (docs/design/e2ee.md §4, PATH-11/PATH-52).
//
// A session starts either pinned — a record from the store, so every dial's TLS
// verifies the phone — or pairing, where TLS itself proves nothing: a
// connection like that must never join (the phone answers an unpinned peer
// `busy`). The phone's `pair.ok` marks the pairing flow verified; the founding
// welcome then adopts the record both ends just verified, so the session's own
// rejoin dials are verified joins instead of attempts the Mac refuses itself.

import Foundation

enum SessionPinState: Equatable {
    /// No pin yet. `verified` is true once this session saw the phone's
    /// `pair.ok`: a reveal the person allowed, with both fingerprints checked.
    case pairing(verified: Bool)
    /// A record every dial pins: its TLS verifies the phone's leaf.
    case pinned(PinnedPhoneV2)

    var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }

    /// The record a dial hands its TLS connector; nil while pairing.
    var record: PinnedPhoneV2? {
        if case .pinned(let record) = self { return record }
        return nil
    }

    /// A closed token for the transition log: never a fingerprint or an id.
    var token: String {
        switch self {
        case .pairing(let verified): return verified ? "pairing-verified" : "pairing"
        case .pinned: return "pinned"
        }
    }
}

enum SessionPinEvent: Equatable {
    /// The phone's `pair.ok`: the person allowed and the two fingerprints the
    /// commit/reveal flow proved match.
    case phoneAllowed
    /// The founding `welcome`. `record` is the complete pin record pairing
    /// established, or nil when the handshake gave nothing TLS could verify.
    case founded(record: PinnedPhoneV2?)

    var token: String {
        switch self {
        case .phoneAllowed: return "pair.ok"
        case .founded(nil): return "welcome-no-record"
        case .founded: return "welcome"
        }
    }
}

extension SessionPinState {
    /// `(state, event) -> (state, moved)`; the session logs the move and owns
    /// the fact that only a verified pairing adopts a complete record. Every
    /// other pair is ignored, never guessed at.
    mutating func handle(_ event: SessionPinEvent) -> Bool {
        switch (self, event) {
        case (.pairing(false), .phoneAllowed):
            self = .pairing(verified: true)
            return true
        case (.pairing(true), .phoneAllowed):
            return false
        case (.pinned, .phoneAllowed):
            return false
        case (.pairing(true), .founded(record: .some(let record))):
            self = .pinned(record)
            return true
        case (.pairing(false), .founded):
            // Before pair.ok the handshake proved nothing about the phone.
            return false
        case (.pairing(true), .founded(record: nil)):
            // No record TLS can verify: the session stays unpinned, so it
            // never joins (PATH-11).
            return false
        case (.pinned, .founded):
            return false
        }
    }
}
