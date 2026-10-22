// The crop maths of a mirror's picture (PictureCrop.swift): the display layer sits in a clip that
// shows only the picture, so a black band outside the picture's rect is never drawn.

import CoreGraphics
import XCTest
@testable import PocketDeck

final class PictureCropTests: XCTestCase {
    func testAWholeFramePictureIsTheLayerExactlyOnTheClip() {
        let rect = PictureCrop.layerFrame(frame: CGSize(width: 608, height: 1312),
                                          content: .full(width: 608, height: 1312),
                                          picture: CGSize(width: 304, height: 656))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 304, height: 656))
    }

    func testABandAtTheRightAndBottomIsCroppedOut() {
        // A 100x200 frame whose picture is the top-left 98x196: the clip shows exactly
        // the picture, so the layer's frame is the frame shifted down by the band.
        let rect = PictureCrop.layerFrame(frame: CGSize(width: 100, height: 200),
                                          content: PictureRect(x: 0, y: 0, w: 98, h: 196),
                                          picture: CGSize(width: 98, height: 196))
        XCTAssertEqual(rect, CGRect(x: 0, y: -4, width: 100, height: 200))
    }

    func testThePictureScalesToTheClip() {
        // The same picture drawn twice as big: the layer's frame doubles with it.
        let rect = PictureCrop.layerFrame(frame: CGSize(width: 100, height: 200),
                                          content: PictureRect(x: 0, y: 0, w: 98, h: 196),
                                          picture: CGSize(width: 196, height: 392))
        XCTAssertEqual(rect, CGRect(x: 0, y: -8, width: 200, height: 400))
    }

    func testAPictureWithBandsOnBothSidesIsCentredOnTheClip() {
        // Content at (10, 20) of a 100x100 frame, 80x60 big: the clip shows that rect.
        let rect = PictureCrop.layerFrame(frame: CGSize(width: 100, height: 100),
                                          content: PictureRect(x: 10, y: 20, w: 80, h: 60),
                                          picture: CGSize(width: 80, height: 60))
        XCTAssertEqual(rect, CGRect(x: -10, y: -20, width: 100, height: 100))
    }

    func testAnEmptyPictureFallsBackToTheClip() {
        let rect = PictureCrop.layerFrame(frame: CGSize(width: 100, height: 200),
                                          content: PictureRect(x: 0, y: 0, w: 0, h: 0),
                                          picture: CGSize(width: 50, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 50, height: 100))
    }
}
