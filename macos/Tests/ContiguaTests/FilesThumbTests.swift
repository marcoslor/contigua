// The extension half's pure decisions (FilesThumbPolicy.swift): which items a
// thumbnail is asked for, and what a failure means to Finder (R-1:
// docs/specs/files.md FILES-22, FILES-26). The extension object itself is built
// by bundle.sh outside the test target, so its two decisions live here where
// K2 can pin them; the glue is proved by the bridge e2e and the VM.

import FileProvider
import XCTest
@testable import Contigua

final class FilesThumbTests: XCTestCase {
    func testAnImageIsMediaAndAPdfIsNot() {
        XCTAssertTrue(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.jpeg"))
        XCTAssertTrue(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.heic"))
        XCTAssertTrue(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.png"))
        XCTAssertFalse(FilesThumbPolicy.isMedia(contentTypeIdentifier: "com.adobe.pdf"))
        XCTAssertFalse(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.plain-text"))
        XCTAssertFalse(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.data"))
    }

    func testAMovieIsMedia() {
        XCTAssertTrue(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.mpeg-4"))
        XCTAssertTrue(FilesThumbPolicy.isMedia(contentTypeIdentifier: "com.apple.quicktime-movie"))
    }

    func testAFolderIsNotMedia() {
        XCTAssertFalse(FilesThumbPolicy.isMedia(contentTypeIdentifier: "public.folder"))
    }

    func testAPhotoPathAsksAndADocumentPathDoesNot() {
        XCTAssertTrue(FilesThumbPolicy.pathIsMedia("DCIM/Camera/photo.jpg"))
        XCTAssertTrue(FilesThumbPolicy.pathIsMedia("DCIM/Camera/clip.mp4"))
        XCTAssertFalse(FilesThumbPolicy.pathIsMedia("Documents/report.pdf"))
        XCTAssertFalse(FilesThumbPolicy.pathIsMedia("Documents/notes.txt"))
        XCTAssertFalse(FilesThumbPolicy.pathIsMedia("DCIM/Camera"))
    }

    func testTheTransientCodesAreTheOnesWorthAskingAgainFor() {
        for code in ["offline", "closed", "timeout", "fs_busy", "busy"] {
            XCTAssertTrue(FilesThumbPolicy.isTransient(code: code), code)
        }
    }

    func testEveryOtherCodeIsPermanent() {
        for code in ["fs_no_thumb", "fs_not_found", "fs_denied", "fs_not_a_dir",
                     "fs_stale", "checksum", "not_media", "bad_version", "io"] {
            XCTAssertFalse(FilesThumbPolicy.isTransient(code: code), code)
        }
    }

    func testATransientFailureAnswersServerUnreachable() {
        let error = FilesThumbPolicy.error(for: "timeout")
        XCTAssertEqual((error as NSError?)?.domain, NSFileProviderErrorDomain)
        XCTAssertEqual((error as NSError?)?.code, NSFileProviderError.serverUnreachable.rawValue)
    }

    func testAPermanentFailureAnswersNilData() {
        XCTAssertNil(FilesThumbPolicy.error(for: "fs_no_thumb"))
        XCTAssertNil(FilesThumbPolicy.error(for: "not_media"))
    }

    func testTheLimitIsThree() {
        XCTAssertEqual(3, FilesThumbPolicy.inFlightLimit)
    }

    func testTheBridgeWaitForOneThumbnailIsLongEnoughForTheQueue() {
        // FILES-29: a queued ask waits for its turn, so the extension's socket
        // must outlive a camera folder's queue — but a dead bridge is still
        // bounded. The cap is 120 s (about 170 photos at 0.7 s each).
        XCTAssertEqual(120, FilesThumbPolicy.bridgeReadTimeout)
        XCTAssertLessThanOrEqual(FilesThumbPolicy.bridgeReadTimeout, 120)
    }
}
