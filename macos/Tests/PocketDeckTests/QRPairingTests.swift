// QR pairing payload, expiry and image (docs/UX.md "Pairing model").

import XCTest
@testable import PocketDeck

final class QRPairingTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func payload(name: String = "Marcos's MacBook Pro", age: TimeInterval = 0) -> PairingQRPayload {
        PairingQRPayload(clientId: "5f0c1d2e-0000-4000-8000-abcdefabcdef",
                         name: name,
                         key: Data(repeating: 0xab, count: 32),
                         createdAt: base.addingTimeInterval(-age))!
    }

    func testURIShape() {
        let uri = payload().uri
        XCTAssertTrue(uri.hasPrefix("pocketdeck://pair?c=5f0c1d2e-0000-4000-8000-abcdefabcdef&n="), uri)
        let key = uri.components(separatedBy: "&k=").last ?? ""
        XCTAssertEqual(key.count, 64)
        XCTAssertEqual(key, String(repeating: "ab", count: 32))
        XCTAssertTrue(key.allSatisfy { $0.isNumber || ("a"..."f").contains($0) })
    }

    func testNameIsPercentEncodedForFormDecoding() {
        let uri = payload(name: "Mac & Co + 1 = 2").uri
        XCTAssertFalse(uri.contains("Mac & Co"))
        XCTAssertFalse(uri.contains("+"))
        XCTAssertFalse(uri.contains("= 2"))
        XCTAssertTrue(uri.contains("Mac%20%26%20Co%20%2B%201%20%3D%202"), uri)
    }

    func testExpiryBoundary() {
        XCTAssertFalse(payload(age: 0).isExpired(now: base))
        XCTAssertFalse(payload(age: 299.9).isExpired(now: base))
        XCTAssertTrue(payload(age: 300).isExpired(now: base))
        XCTAssertTrue(payload(age: 400).isExpired(now: base))
        XCTAssertEqual(payload(age: 60).remaining(now: base), 240, accuracy: 0.001)
        XCTAssertEqual(payload(age: 400).remaining(now: base), 0, accuracy: 0.001)
    }

    func testRandomKeysAre32BytesAndUnique() {
        let first = PairingQRPayload.random(clientId: "c", name: "n")
        let second = PairingQRPayload.random(clientId: "c", name: "n")
        XCTAssertEqual(first?.key.count, 32)
        XCTAssertEqual(second?.key.count, 32)
        XCTAssertNotEqual(first?.key, second?.key)
    }

    func testRejectsWrongKeyLengthAndEmptyClientId() {
        XCTAssertNil(PairingQRPayload(clientId: "c", name: "n", key: Data(repeating: 0, count: 31)))
        XCTAssertNil(PairingQRPayload(clientId: "", name: "n", key: Data(repeating: 0, count: 32)))
    }

    func testQRImageIsDrawnCrisplyOnWhite() throws {
        let image = try XCTUnwrap(QRCode.image(from: payload().uri, moduleSize: 4, quietModules: 2))
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertEqual(image.size.width, image.size.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        // Quiet zone is white and the middle of the code is not.
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.9)
        var dark = 0
        for x in stride(from: rep.pixelsWide / 3, to: rep.pixelsWide * 2 / 3, by: 3) {
            for y in stride(from: rep.pixelsHigh / 3, to: rep.pixelsHigh * 2 / 3, by: 3)
            where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
                dark += 1
            }
        }
        XCTAssertGreaterThan(dark, 0, "QR image is blank")
    }
}
