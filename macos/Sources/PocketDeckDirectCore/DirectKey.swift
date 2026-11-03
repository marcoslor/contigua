#if POCKETDECK_DIRECT
import CryptoKit
import Foundation

/// The 32-byte NDP key (docs/design/direct-link.md §5, transport DIRECT-9):
/// 64 lowercase hex on the wire, base64 for the platform's passphrase, and an
/// 8-hex SHA-256 prefix as its only log form. P3's `DirectKey` is the phone
/// half of this file, vector for vector.
public enum DirectKey {
    public static let byteCount = 32
    public static let hexLength = byteCount * 2

    /// Exactly 64 hex characters, either case, like the phone's parser.
    public static func parse(_ raw: String?) -> [UInt8]? {
        guard let raw, raw.count == hexLength else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(byteCount)
        var index = raw.startIndex
        for _ in 0..<byteCount {
            guard let hi = hexValue(raw[index]) else { return nil }
            index = raw.index(after: index)
            guard let lo = hexValue(raw[index]) else { return nil }
            index = raw.index(after: index)
            out.append((hi << 4) | lo)
        }
        return out
    }

    public static func hex(_ key: [UInt8]) -> String {
        key.map { String(format: "%02x", $0) }.joined()
    }

    /// §5: the Wi-Fi Aware passphrase is the base64 of the raw bytes.
    public static func passphrase(_ key: [UInt8]) -> String {
        Data(key).base64EncodedString()
    }

    /// R-PRIV-1's one key line: the first 8 hex of SHA-256(key).
    public static func fingerprint(_ key: [UInt8]) -> String {
        hex(Array(SHA256.hash(data: Data(key)).prefix(4)))
    }

    private static func hexValue(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x61...0x66: return ascii - 0x61 + 10
        case 0x41...0x46: return ascii - 0x41 + 10
        default: return nil
        }
    }
}

public extension NanSsi {
    static let windowSeconds: Int64 = 600

    static func window(epochSeconds: Int64) -> Int64 {
        epochSeconds / windowSeconds
    }

    /// §6: `HMAC-SHA256(psk, "pd-nan-v1" || u64_be(window))[0..8]`.
    static func bytes(key: [UInt8], window: Int64) -> NanSsi {
        var message = Array("pd-nan-v1".utf8)
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: window >> Int64(shift)))
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message), using: SymmetricKey(data: Data(key)))
        return NanSsi(Array(code.prefix(8)))
    }

    static func hex(key: [UInt8], window: Int64) -> String {
        bytes(key: key, window: window).hex
    }

    /// The current window and its two neighbours, so a clock a few minutes
    /// off still matches (DIRECT-10).
    static func accepted(key: [UInt8], epochSeconds: Int64) -> [NanSsi] {
        let current = window(epochSeconds: epochSeconds)
        return [-1, 0, 1].map { bytes(key: key, window: current + Int64($0)) }
    }

    static func accepts(_ published: NanSsi, key: [UInt8],
                        epochSeconds: Int64) -> Bool {
        accepted(key: key, epochSeconds: epochSeconds).contains(published)
    }
}
#endif
