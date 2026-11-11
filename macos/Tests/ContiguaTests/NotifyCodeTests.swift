import AppKit
import XCTest
@testable import Contigua

// Sign-in codes and Copy code (docs/design/notify.md, part 2). All values here
// are fake fixtures; nothing is read from or written to a person's clipboard.

final class NotifyCodeTests: XCTestCase {

    // MARK: positives

    func testFindsCodesInEnglishPortugueseAndSpanish() {
        let positives: [(String?, String?)] = [
            ("Your code is 482913", nil),
            (nil, "482913 is your verification code"),
            ("Código: 7315", nil),
            ("Seu código de verificação é 902144", nil),
            (nil, "OTP 556677"),
            ("PIN: 4821", nil),
            ("Use passcode 9182", nil),
            ("Code 4417", nil),
            (nil, "A1B2C3 is your login code"),
            ("code 12AB34CD", nil),
            (nil, "verification: 7K2M9Q"),
            ("Your security code 12345678", nil),
            ("código 102938", nil),
            ("verificação 483920", nil),
            ("Enter the code 0021", nil),
            ("code: 2024", nil),
            ("OTP is 99X1Y2", nil),
            ("PIN 0000", nil),
            ("Code below:\n5566", nil),
            (nil, "your one-time code\n662211"),
            ("codigo 5561", nil),
            ("Senha 8821 — code 4471", nil),
            ("Password: code 7391", nil),
        ]
        for (title, text) in positives {
            XCTAssertNotNil(NotifyCode.find(title: title, text: text),
                            "expected a code in title=\(title ?? "-") text=\(text ?? "-")")
        }
    }

    // MARK: negatives

    func testRejectsOrdinaryNumbersAndWeakerShapes() {
        let negatives: [(String?, String?)] = [
            ("Order 123456 shipped", nil),
            ("Call 5551234", nil),
            (nil, "Your code expires in 10 minutes"),
            ("Verification code sent", nil),
            ("Total $1,299", nil),
            (nil, "Your code: 123456789"),
            ("Date 2026-10-20 code", nil),
            ("Phone +1 415 555 1234", nil),
            ("Your code is 1234-5678", nil),
            ("15:42 code", nil),
            ("99.99 code", nil),
            ("Discount 2500% code", nil),
            ("Your code is ABCDEF", nil),
            ("Your code is ABCDE1", nil),
            ("code 123", nil),
            ("code 1234567890", nil),
            ("PIN 12", nil),
            ("password 482913", nil),
            ("senha 482913", nil),
            ("Your code is 20/10/2026", nil),
            ("code +447700900123", nil),
            ("shipping 482913", nil),
            (nil, "Invoice 998877 due Friday"),
            ("Nothing to see 5566", nil),
        ]
        for (title, text) in negatives {
            XCTAssertNil(NotifyCode.find(title: title, text: text),
                         "expected no code in title=\(title ?? "-") text=\(text ?? "-")")
        }
    }

    func testEmptyFieldsHaveNoCode() {
        XCTAssertNil(NotifyCode.find(title: nil, text: nil))
        XCTAssertNil(NotifyCode.find(title: "", text: ""))
    }

    // MARK: clipboard

    private final class FakePasteboard: CodePasteboard {
        var changeCount = 0
        var text: String?
        func writeConcealed(_ text: String) {
            self.text = text
            changeCount += 1
        }
        func clear() {
            text = nil
            changeCount += 1
        }
    }

    func testCopyWritesTheCodeAndClearsItAfterNinetySeconds() {
        let pasteboard = FakePasteboard()
        var jobs: [(TimeInterval, () -> Void)] = []
        let copy = CodeCopy(pasteboard: pasteboard) { delay, block in jobs.append((delay, block)) }
        XCTAssertEqual(copy.copy("482913"), 6)
        XCTAssertEqual(pasteboard.text, "482913")
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].0, CodeCopy.lifetime)
        XCTAssertEqual(CodeCopy.lifetime, 90)
        jobs[0].1()
        XCTAssertNil(pasteboard.text, "still ours after 90 s: cleared")
    }

    func testCopyLeavesANewerPasteboardItemAlone() {
        let pasteboard = FakePasteboard()
        var jobs: [(TimeInterval, () -> Void)] = []
        let copy = CodeCopy(pasteboard: pasteboard) { delay, block in jobs.append((delay, block)) }
        copy.copy("482913")
        pasteboard.text = "something the person copied later"
        pasteboard.changeCount += 1
        jobs[0].1()
        XCTAssertEqual(pasteboard.text, "something the person copied later",
                       "changeCount moved: the clear must not run")
    }

    func testSystemPasteboardMarksTheItemConcealedAndTransient() {
        // A private named pasteboard: the person's clipboard is never touched.
        let name = NSPasteboard.Name("pd-notify2-tests-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.clearContents() }
        let writer = SystemCodePasteboard(pasteboard: pasteboard)
        writer.writeConcealed("482913")
        XCTAssertEqual(pasteboard.string(forType: .string), "482913")
        XCTAssertNotNil(pasteboard.data(forType: SystemCodePasteboard.concealed))
        XCTAssertNotNil(pasteboard.data(forType: SystemCodePasteboard.transient))
        writer.clear()
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
