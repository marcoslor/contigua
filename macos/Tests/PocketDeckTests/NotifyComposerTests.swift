import AppKit
import XCTest
@testable import PocketDeck

// The composed notification attachment (NOTIFY-22, docs/design/notify.md § "The
// attachment's app badge"): a picture cut to a circle with the sender's icon as
// a badge, or the icon alone in a rounded square. These tests read pixels, so
// the fixture art is generated, never a real picture.
final class NotifyComposerTests: XCTestCase {

    // MARK: fixtures

    /// An sRGB image, `colour` in top-left pixel coordinates.
    private func image(width: Int, height: Int,
                       _ colour: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = colour(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &bytes, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func solid(_ width: Int, _ height: Int,
                       _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        image(width: width, height: height) { _, _ in rgba }
    }

    /// The app icon fixture: a green square with a magenta centre block, so the
    /// badge's centre pixel can only be the icon's own centre.
    private func fixtureIcon(side: Int = 256) -> CGImage {
        image(width: side, height: side) { x, y in
            let centre = side / 2, half = max(2, side / 12)
            if abs(x - centre) < half, abs(y - centre) < half {
                return (230, 30, 190, 255)
            }
            return (30, 200, 90, 255)
        }
    }

    private func icon(_ flat: CGImage, sizeClass: IconSizeClass = .deck) -> NotifyAttachmentComposer.Icon {
        NotifyAttachmentComposer.Icon(candidates: [
            NotifyAttachmentComposer.IconCandidate(layers: nil, flat: flat, sizeClass: sizeClass),
        ])
    }

    /// The PNG's pixels, row 0 at the top.
    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
        }

        var cornerAlphas: [UInt8] {
            [at(0, 0).a, at(width - 1, 0).a, at(0, height - 1).a, at(width - 1, height - 1).a]
        }
    }

    private func pixels(_ data: Data) -> Pixels {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, rgba: bytes)
    }

    private func attachment(_ outcome: NotifyAttachmentComposer.Outcome,
                            file: StaticString = #filePath, line: UInt = #line)
        -> NotifyAttachmentComposer.ComposedAttachment {
        guard let attachment = outcome.attachment else {
            XCTFail("no composed attachment (fallback \(String(describing: outcome.fallback)))",
                    file: file, line: line)
            fatalError("no composed attachment")
        }
        return attachment
    }

    /// The badge's centre in top-left pixel coordinates (the composer draws it
    /// inset from the bottom-right in CG coordinates).
    private func badgeCentre(side: Int) -> (x: Int, y: Int) {
        let badge = CGFloat(side) * NotifyAttachmentComposer.badgeFraction
        let inset = CGFloat(side) * NotifyAttachmentComposer.badgeInsetFraction
        let x = Int((CGFloat(side) - inset - badge / 2).rounded())
        let cgY = inset + badge / 2
        let y = Int((CGFloat(side) - 1 - cgY).rounded())
        return (x, y)
    }

    private func assertColour(_ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                              _ expected: (UInt8, UInt8, UInt8), tolerance: Int = 12,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pixel.a, 255, "\(message): alpha \(pixel.a)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixel.r) - Int(expected.0)), tolerance,
                                 "\(message): red \(pixel.r) vs \(expected.0)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixel.g) - Int(expected.1)), tolerance,
                                 "\(message): green \(pixel.g) vs \(expected.1)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixel.b) - Int(expected.2)), tolerance,
                                 "\(message): blue \(pixel.b) vs \(expected.2)", file: file, line: line)
    }

    private func assertNearBlack(_ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                                 _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let isBackdropGrey = abs(Int(pixel.r) - Int(pixel.g)) < 8
            && abs(Int(pixel.g) - Int(pixel.b)) < 8 && pixel.r < 160
        XCTAssertFalse(pixel.r < 40 && pixel.g < 40 && pixel.b < 40,
                       "\(message): near-black \(pixel)", file: file, line: line)
        XCTAssertFalse(isBackdropGrey, "\(message): backdrop grey \(pixel)", file: file, line: line)
    }

    // MARK: shape

    func testACirclePictureHasTransparentCorners() {
        let picture = solid(200, 100, (255, 40, 40, 255))
        let outcome = NotifyAttachmentComposer.compose(picture: picture, icon: icon(fixtureIcon()))
        let composed = attachment(outcome)
        XCTAssertEqual(composed.shape, .circle)
        XCTAssertEqual(composed.side, 200)
        let pixels = pixels(composed.data)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 200)
        XCTAssertEqual(pixels.cornerAlphas, [0, 0, 0, 0], "the circle's corners are transparent")
        assertColour(pixels.at(100, 2), (255, 40, 40), "the circle's top edge is the picture")
    }

    func testTheBadgeCentreCarriesTheIconsCentreColour() {
        let picture = solid(200, 100, (255, 40, 40, 255))
        let outcome = NotifyAttachmentComposer.compose(picture: picture, icon: icon(fixtureIcon()))
        let composed = attachment(outcome)
        XCTAssertTrue(composed.badge)
        let centre = badgeCentre(side: composed.side)
        let pixel = pixels(composed.data).at(centre.x, centre.y)
        assertColour(pixel, (230, 30, 190), "the badge's centre is the icon's centre")
    }

    func testThereIsNoRingAroundTheBadge() {
        // NOTIFY-22: the badge sits straight on the picture. A backdrop ring
        // would show as a dark or grey band just outside its circle.
        let picture = solid(200, 100, (255, 40, 40, 255))
        let outcome = NotifyAttachmentComposer.compose(picture: picture, icon: icon(fixtureIcon()))
        let composed = attachment(outcome)
        let centre = badgeCentre(side: composed.side)
        let badge = Int((CGFloat(composed.side) * NotifyAttachmentComposer.badgeFraction).rounded())
        let pixels = pixels(composed.data)
        // The badge's outer corner overlaps the circle's arc; the two edges
        // that sit inside the picture are where a backdrop ring would show.
        let samples = [
            pixels.at(centre.x - badge / 2 - 3, centre.y),
            pixels.at(centre.x, centre.y - badge / 2 - 3),
        ]
        for (index, pixel) in samples.enumerated() {
            assertNearBlack(pixel, "sample \(index) outside the badge")
        }
        assertColour(samples[0], (255, 40, 40), "left of the badge is the picture")
        assertColour(samples[1], (255, 40, 40), "above the badge is the picture")
    }

    func testTheIconAloneFillsTheSquareInsideItsCorners() {
        let outcome = NotifyAttachmentComposer.compose(picture: nil, icon: icon(fixtureIcon(side: 512)))
        let composed = attachment(outcome)
        XCTAssertEqual(composed.shape, .icon, "an icon alone is never a circle")
        XCTAssertEqual(composed.side, NotifyAttachmentComposer.iconSide)
        let pixels = pixels(composed.data)
        XCTAssertEqual(pixels.cornerAlphas, [0, 0, 0, 0], "the corners sit outside the 22 % rounding")
        for (x, y) in [(pixels.width / 2, 2), (pixels.width / 2, pixels.height - 3),
                       (2, pixels.height / 2), (pixels.width - 3, pixels.height / 2)] {
            XCTAssertEqual(pixels.at(x, y).a, 255, "the icon reaches the edge's midpoint at (\(x), \(y))")
        }
        assertColour(pixels.at(pixels.width / 2, pixels.height / 2), (230, 30, 190),
                     "the icon's centre is the tile's centre")
    }

    func testThePictureCoversTheSquareWithoutLetterboxing() {
        // A 4:1 picture: its top half is red and its bottom half blue. Cover
        // keeps red at the top and blue at the bottom; letterboxing would leave
        // transparent bands there instead.
        let picture = image(width: 400, height: 100) { _, y in
            y < 50 ? (255, 40, 40, 255) : (40, 60, 255, 255)
        }
        let composed = attachment(NotifyAttachmentComposer.compose(picture: picture, icon: nil))
        XCTAssertEqual(composed.side, 400)
        let pixels = pixels(composed.data)
        assertColour(pixels.at(200, 2), (255, 40, 40), "the picture's top edge fills the circle")
        assertColour(pixels.at(200, 397), (40, 60, 255), "the picture's bottom edge fills the circle")
    }

    func testTheSideFollowsThePictureOrTheIconAlone() {
        let side: (Int, Int) -> Int = { width, height in
            NotifyAttachmentComposer.compose(picture: self.solid(width, height, (1, 2, 3, 255)),
                                             icon: nil).attachment?.side ?? 0
        }
        XCTAssertEqual(side(700, 400), 512, "512 is the ceiling")
        XCTAssertEqual(side(200, 100), 200, "a small picture keeps its long side")
        XCTAssertEqual(side(1200, 300), 512)
        XCTAssertEqual(side(120, 300), 300)
        XCTAssertEqual(NotifyAttachmentComposer.compose(picture: nil, icon: icon(fixtureIcon()))
                           .attachment?.side, 256, "the icon alone is 256 px")
    }

    // MARK: caps and fallbacks

    func testASmoothPictureStaysUnderTheCap() {
        let picture = solid(512, 512, (240, 240, 240, 255))
        let composed = attachment(NotifyAttachmentComposer.compose(picture: picture, icon: icon(fixtureIcon())))
        XCTAssertLessThanOrEqual(composed.data.count, NotifyAttachmentComposer.maxBytes,
                                 "the composed PNG stays inside 200 KiB")
        XCTAssertLessThanOrEqual(composed.data.count, NotifyImageCaps.maxBytes,
                                 "and inside the Mac's own image cap")
        XCTAssertNil(NotifyImageCaps.refusal(mime: composed.mime, width: composed.side,
                                             height: composed.side, decoded: composed.data.count))
    }

    func testANoisyPictureOverTheCapFallsBack() {
        // Per-pixel noise does not compress: 512 px is far over 200 KiB, so the
        // composer refuses and the caller keeps the phone's picture uncomposed.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        let picture = image(width: 512, height: 512) { _, _ in
            (next(), next(), next(), 255)
        }
        let outcome = NotifyAttachmentComposer.compose(picture: picture, icon: icon(fixtureIcon()))
        XCTAssertNil(outcome.attachment, "over the cap the composition is refused")
        XCTAssertEqual(outcome.fallback, .overCap)
        XCTAssertEqual(outcome.record, "composed fallback=over_cap")
    }

    func testNoCachedIconKeepsTheCircleWithoutABadge() {
        let picture = solid(200, 100, (255, 40, 40, 255))
        let composed = attachment(NotifyAttachmentComposer.compose(picture: picture, icon: nil))
        XCTAssertEqual(composed.shape, .circle)
        XCTAssertFalse(composed.badge)
        XCTAssertEqual(composed.record, "composed shape=circle badge=no side=200 class=none")
    }

    func testNoIconAndNoPictureAttachNothing() {
        let outcome = NotifyAttachmentComposer.compose(picture: nil, icon: nil)
        XCTAssertNil(outcome.attachment)
        XCTAssertEqual(outcome.fallback, .noIcon)
        XCTAssertEqual(outcome.record, "composed fallback=no_icon")
    }

    func testAnIconBelowTheUpscaleBoundIsNotUsed() {
        // A 64 px source drawn at 256 px would be 4×, past docs/NFR.md's 1.3×.
        let tiny = fixtureIcon(side: 64)
        XCTAssertLessThanOrEqual(NotifyAttachmentComposer.maxUpscale,
                                 NFRTestLimits.shared.double("icon_covered_flat_scale"))
        let outcome = NotifyAttachmentComposer.compose(picture: nil, icon: icon(tiny))
        XCTAssertNil(outcome.attachment)
        XCTAssertEqual(outcome.fallback, .noIcon)
    }

    // MARK: the review's fixtures

    /// The four cases the reviewer looks at (brief: .agent/notify-badge/
    /// composed-*.png). Generated art, written to /tmp so the run leaves the
    /// proof beside the task.
    func testTheReviewFixturesAreWritten() throws {
        let directory = URL(fileURLWithPath: "/tmp/pocketdeck-notify-badge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var photoBytes = [UInt8](repeating: 0, count: 400 * 300 * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let photo = CGContext(data: &photoBytes, width: 400, height: 300, bitsPerComponent: 8,
                              bytesPerRow: 400 * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(colorSpace: space, components: [0.09, 0.30, 0.55, 1])!,
            CGColor(colorSpace: space, components: [0.85, 0.45, 0.15, 1])!,
        ] as CFArray, locations: [0, 1])!
        photo.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 300),
                                 end: CGPoint(x: 400, y: 0), options: [])
        photo.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.25])!)
        photo.fillEllipse(in: CGRect(x: 225, y: 156, width: 112, height: 112))
        let picture = photo.makeImage()!

        let iconArt = image(width: 512, height: 512) { x, y in
            let dx = Double(x - 256), dy = Double(y - 256), distance = (dx * dx + dy * dy).squareRoot()
            if distance < 120 { return (255, 255, 255, 255) }
            return (37, 211, 102, 255)
        }
        let appIcon = icon(iconArt, sizeClass: .deck)

        let cases: [(String, CGImage?, NotifyAttachmentComposer.Icon?)] = [
            ("composed-picture-icon", picture, appIcon),
            ("composed-picture-no-icon", picture, nil),
            ("composed-icon", nil, appIcon),
            ("composed-none", nil, nil),
        ]
        for (name, picture, icon) in cases {
            let outcome = NotifyAttachmentComposer.compose(picture: picture, icon: icon)
            if let attachment = outcome.attachment {
                XCTAssertEqual(attachment.mime, "image/png")
                try attachment.data.write(to: directory.appendingPathComponent(name + ".png"))
            } else {
                try outcome.record.write(to: directory.appendingPathComponent(name + ".txt"),
                                         atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: wiring into the banner

    @MainActor
    func testAPostWithAPictureAndACachedIconRecordsTheComposition() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-compose-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("posts.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = NotifyCenter()
        center.log = log
        center.hold = 0.25
        center.attachmentRoot = directory.appendingPathComponent("attachments", isDirectory: true)
        center.iconFor = { _, _ in self.icon(self.fixtureIcon()) }
        let picture = try XCTUnwrap(NSBitmapImageRep(cgImage: solid(200, 100, (255, 40, 40, 255)))
            .representation(using: .png, properties: [:]))
        center.post(PhoneNotification(id: "c1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One", alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        center.image(id: "c1", mime: "image/png", width: 200, height: 100, data: picture)
        let settled = expectation(description: "the hold elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let post = lines.first { $0.hasPrefix("notify post id=c1 ") }
        XCTAssertTrue(post?.contains(" composed shape=circle badge=yes side=200 class=deck ") == true,
                      "the post says what it attached: \(post ?? "none")")
        XCTAssertTrue(post?.contains(" image=image/png w=200 h=200 ") == true,
                      "the composed PNG's own facts: \(post ?? "none")")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: center.attachmentRoot!, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, 1,
                       "one composed attachment on disk")
    }

    @MainActor
    func testAPostWithNoPictureAndACachedIconHasAnAttachment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-icon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("posts.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = NotifyCenter()
        center.log = log
        center.hold = 0
        center.attachmentRoot = directory.appendingPathComponent("attachments", isDirectory: true)
        center.iconFor = { _, _ in self.icon(self.fixtureIcon(side: 512)) }
        center.post(PhoneNotification(id: "c2", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "No picture", alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let post = lines.first { $0.hasPrefix("notify post id=c2 ") }
        XCTAssertTrue(post?.contains(" composed shape=icon badge=no side=256 class=deck ") == true,
                      "the icon alone is the attachment: \(post ?? "none")")
        XCTAssertTrue(post?.contains(" image=image/png w=256 h=256 ") == true,
                      "the post carries the icon's facts: \(post ?? "none")")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: center.attachmentRoot!, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(files.filter { $0.pathExtension == "png" }.count, 1,
                       "the icon-only attachment is on disk")
    }
}
