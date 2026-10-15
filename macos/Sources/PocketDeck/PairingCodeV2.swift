// Mac side of phase-2 step 6 (docs/design/e2ee.md §4, R1): the commit/nonce/
// reveal pairing code and the QR-path HMAC. Byte-identical inputs, formula
// and output to dev.pocketdeck.e2ee.PairingCodeV2 on Android; both sides pin
// the same constants.

import CryptoKit
import Foundation

enum PairingCodeV2 {
    static let commitLabel = "pd-commit-v2"
    static let codeLabel = "pd-code-v2"
    static let qrLabel = "pd-qr-v2"

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func commit(Np: Data, phoneFp: Data, macFp: Data) -> Data {
        var d = Data(commitLabel.utf8)
        d.append(Np); d.append(phoneFp); d.append(macFp)
        return sha256(d)
    }

    static func code(exporter: Data, macFp: Data, phoneFp: Data, Nm: Data, Np: Data) -> Int {
        var d = Data(codeLabel.utf8)
        d.append(exporter); d.append(macFp); d.append(phoneFp); d.append(Nm); d.append(Np)
        let h = sha256(d)
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(h[h.startIndex + i])
        }
        return Int(v % 1_000_000)
    }

    static func codeHex(_ value: Int) -> String {
        String(format: "%06d", value)
    }

    /// HMAC-SHA256(secret, "pd-qr-v2" || exporter || phoneFp).
    static func qrHmac(secret: Data, exporter: Data, phoneFp: Data) -> Data {
        var message = Data(qrLabel.utf8)
        message.append(exporter); message.append(phoneFp)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(mac)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
