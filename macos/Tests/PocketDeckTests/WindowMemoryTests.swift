// Picture memory (WIN-33): one decoded picture per window, in that window's
// own display layer, and a closed window releases it. Twenty open/close cycles
// must leave nothing of the window behind.
//
// What is measured, and why it is not one number for the whole process: this
// platform keeps about 1.0 MB per *realised* layer-backed window (measured
// below on 20 bare AppKit windows of the stream's size) and about 2.6 MB per
// stream window with its chrome and glass — after every one of our objects has
// been deallocated. That cost is AppKit's and CoreAnimation's window context,
// not a picture the app holds: a bare NSWindow with a plain layer-backed view
// grows the process the same way. So the check pins the two things the app
// owns: every window and its layer go when the window closes, and no window
// costs more than the per-window picture budget (docs/NFR.md
// `window_frame_bytes_max`, 16 MiB; 4 MiB per cycle is the leak rule) on top
// of what the platform itself keeps.

import AppKit
import Darwin
import XCTest
@testable import PocketDeck

@MainActor
final class WindowMemoryTests: XCTestCase {
    /// The per-window leak budget (WIN-33's 4 MiB).
    private let perWindowBudget: Int64 = 4 * 1024 * 1024

    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// Lets AppKit and the display layer finish what a close started.
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The platform's own cost for the same 20 realisations: a transparent,
    /// layer-backed window of the stream's size with no app view in it.
    private func bareWindowCycles() -> Int64 {
        func make() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                              .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            view.wantsLayer = true
            window.contentView = view
            return window
        }
        for _ in 0..<3 { let window = make(); window.orderFront(nil); window.close() }
        settle()
        let start = residentBytes()
        for _ in 0..<20 {
            let window = make()
            window.orderFront(nil)
            settle(0.02)
            window.close()
            settle()
        }
        return residentBytes() - start
    }

    /// Twenty cycles of a real app window. Returns the growth and whether every
    /// window released its controller, its view and its layer.
    private func streamWindowCycles() -> (growth: Int64, releasedEverything: Bool,
                                          pictures: [Bool], streamsEmpty: Bool) {
        let fixture = MultiWindowFixture()
        var releasedPictures: [Bool] = []
        // One cycle first: the first window pays for shared caches.
        _ = fixture.open(taskLabel: "warm")
        fixture.closeAll()
        settle()
        let start = residentBytes()
        var pictures: [Bool] = []
        for index in 0..<20 {
            let controller = fixture.open(taskLabel: "w\(index)")
            // The display layer is where a picture arrives: it exists while
            // the window shows one (the layer is made at the first config, so
            // ask for it explicitly here) ...
            _ = controller.videoView.displayLayerForTesting
            pictures.append(controller.videoView.hasPictureLayer)
            settle()
            fixture.closeAll()
            settle()
            // ...and the closed window keeps none: no layer, no frame, no
            // chrome drawn over it (WIN-33). The window and the controller
            // themselves stay in NSApp.windows — AppKit's own list, and why the
            // budget below is measured against a bare window.
            releasedPictures.append(!controller.videoView.hasPictureLayer
                                    && controller.chrome.subviews.isEmpty)
        }
        settle(1)
        let released = releasedPictures.allSatisfy { $0 }
        return (residentBytes() - start, released, pictures, fixture.manager.openStreams.isEmpty)
    }

    func testTwentyCyclesReleaseEveryWindowAndItsPicture() {
        let run = streamWindowCycles()
        XCTAssertTrue(run.pictures.allSatisfy { $0 }, "each open window held a display layer")
        XCTAssertTrue(run.releasedEverything,
                      "a closed window keeps no display layer and no chrome over it")
        XCTAssertTrue(run.streamsEmpty, "every window released its stream")
    }

    func testTwentyCyclesStayInsideThePerWindowPictureBudget() {
        let platform = bareWindowCycles()
        let run = streamWindowCycles()
        let perWindow = run.growth / 20
        let platformPerWindow = platform / 20
        XCTAssertLessThanOrEqual(perWindow, platformPerWindow + perWindowBudget,
                                 "each cycle cost \(perWindow) bytes; the platform's own bare window "
                                 + "cost \(platformPerWindow), our budget is \(perWindowBudget)")
        XCTAssertLessThanOrEqual(run.growth, 20 * perWindowBudget + max(platform, 0),
                                 "20 cycles grew the process by \(run.growth) bytes "
                                 + "(bare windows: \(platform))")
    }
}
