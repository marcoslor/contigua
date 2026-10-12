// QR pairing (docs/UX.md, "Pairing model"): the payload the Mac shows, its
// 5-minute lifetime, and the QR image itself. The payload and expiry rules are
// pure so the unit tests pin them.

import AppKit
import CoreImage
import Security

struct PairingQRPayload: Equatable {
    static let keyByteCount = 32
    /// The QR is only valid for five minutes (docs/UX.md).
    static let lifetime: TimeInterval = 300

    let clientId: String
    let name: String
    /// 32 raw key bytes; the QR carries them as 64 lowercase hex characters.
    let key: Data
    let createdAt: Date

    init?(clientId: String, name: String, key: Data, createdAt: Date = Date()) {
        guard !clientId.isEmpty, key.count == Self.keyByteCount else { return nil }
        self.clientId = clientId
        self.name = name
        self.key = key
        self.createdAt = createdAt
    }

    /// A fresh random key (SecRandomCopyBytes) for one QR sheet.
    static func random(clientId: String, name: String, now: Date = Date()) -> PairingQRPayload? {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return PairingQRPayload(clientId: clientId, name: name, key: Data(bytes), createdAt: now)
    }

    var keyHex: String { key.map { String(format: "%02x", $0) }.joined() }

    /// `pocketdeck://pair?c=<clientId>&n=<url-encoded name>&k=<64 hex>`
    var uri: String {
        "pocketdeck://pair?c=\(Self.percentEncoded(clientId))&n=\(Self.percentEncoded(name))&k=\(keyHex)"
    }

    func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= Self.lifetime
    }

    func remaining(now: Date = Date()) -> TimeInterval {
        max(0, Self.lifetime - now.timeIntervalSince(createdAt))
    }

    /// Query-value encoding: only unreserved characters stay literal, so `&`,
    /// `=` and `+` in a device name survive the phone's form decoding.
    static func percentEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

enum QRCode {
    /// Crisp QR bitmap: the generator's own modules drawn with no interpolation
    /// onto a white canvas with a 2-module quiet zone (ISO 18004 requires 4 for
    /// scanners; 2 is plenty for a screen and keeps the image small).
    static func image(from string: String, moduleSize: Int = 8, quietModules: Int = 2) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let modules = Int(output.extent.width.rounded())
        guard modules > 0 else { return nil }
        let side = (modules + quietModules * 2) * moduleSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let modulesImage = ciContext.createCGImage(output, from: output.extent) else { return nil }
        context.draw(modulesImage, in: CGRect(x: quietModules * moduleSize, y: quietModules * moduleSize,
                                              width: modules * moduleSize, height: modules * moduleSize))
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
