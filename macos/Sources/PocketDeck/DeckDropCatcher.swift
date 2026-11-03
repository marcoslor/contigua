// The Deck's AppKit drop destination (SHARE-18): SwiftUI's URL-only
// `dropDestination` cannot see image data or file promises, so one transparent
// background view reads the same D1 order the stream windows use.

import AppKit
import SwiftUI

struct DeckDropCatcher: NSViewRepresentable {
    let onDrop: (DropDrag) -> Void

    func makeNSView(context: Context) -> DropView {
        DropView(onDrop: onDrop)
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        var onDrop: (DropDrag) -> Void

        init(onDrop: @escaping (DropDrag) -> Void) {
            self.onDrop = onDrop
            super.init(frame: .zero)
            registerForDraggedTypes([.fileURL] + DropDragReader.imageTypes
                                    + DropDragReader.promiseTypes + [.URL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: the view is never decoded

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            DropDragReader.canRead(sender.draggingPasteboard) ? .copy : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            DropDragReader.canRead(sender.draggingPasteboard) ? .copy : []
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let drag = DropDragReader.read(sender.draggingPasteboard) else { return false }
            onDrop(drag)
            return true
        }
    }
}
