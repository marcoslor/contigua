import CryptoKit
import Foundation
import XCTest
@testable import PocketDeck

final class PairingCodeV2Tests: XCTestCase {
    private func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func zeros(_ n: Int) -> Data { Data(repeating: 0, count: n) }
    private func first16(_ d: Data) -> Data { d.prefix(16) }

    func testVectorA() {
        let np = zeros(16); let phone = zeros(32); let mac = zeros(32)
        let commit = PairingCodeV2.commit(Np: np, phoneFp: phone, macFp: mac)
        XCTAssertEqual(PairingCodeV2.hex(commit), "4db996acf8699876c00680a004258f80b6027b3e486fef58cbd47b3c4c2d55b0")
        let exporter = zeros(32)
        let nm = zeros(16)
        let code = PairingCodeV2.code(exporter: exporter, macFp: mac, phoneFp: phone, Nm: nm, Np: np)
        XCTAssertEqual(PairingCodeV2.codeHex(code), "063680")
        let h = PairingCodeV2.sha256({
            var d = Data("pd-code-v2".utf8); d.append(exporter); d.append(mac); d.append(phone); d.append(nm); d.append(np); return d
        }())
        XCTAssertEqual(PairingCodeV2.hex(h), "f28c00a27dc8c40011fa37bc093e4681ca8bde98fc8f84454a3aa21cc4f9d578")
    }

    func testVectorB() {
        let exporter = sha256(Data("pd-v2-vector exporter".utf8))
        let mac = sha256(Data("pd-v2-vector mac".utf8))
        let phone = sha256(Data("pd-v2-vector phone".utf8))
        let nm = first16(sha256(Data("pd-v2-vector Nm".utf8)))
        let np = first16(sha256(Data("pd-v2-vector Np".utf8)))
        let commit = PairingCodeV2.commit(Np: np, phoneFp: phone, macFp: mac)
        XCTAssertEqual(PairingCodeV2.hex(commit), "1416bfb0ad52d1e41616118ef7a672aca9bd2bd1c8bf72dde845536749ca53f0")
        let code = PairingCodeV2.code(exporter: exporter, macFp: mac, phoneFp: phone, Nm: nm, Np: np)
        XCTAssertEqual(PairingCodeV2.codeHex(code), "694339")
        let h = PairingCodeV2.sha256({
            var d = Data("pd-code-v2".utf8); d.append(exporter); d.append(mac); d.append(phone); d.append(nm); d.append(np); return d
        }())
        XCTAssertEqual(PairingCodeV2.hex(h), "826dde3dd5847d43a449eb3158908849c2205bc56cbcab124f3dac041018a8ae")
    }

    func testQrHmacVector() {
        let secret = Data(repeating: 0x42, count: 16)
        let exporter = Data(repeating: 0x11, count: 32)
        let phone = Data(repeating: 0x22, count: 32)
        let hmac = PairingCodeV2.qrHmac(secret: secret, exporter: exporter, phoneFp: phone)
        XCTAssertEqual(PairingCodeV2.hex(hmac), "1d82caee8640b5e9829ad0f44033261622d29e54a0214b300ff5cd6850e74ece")
    }
}
