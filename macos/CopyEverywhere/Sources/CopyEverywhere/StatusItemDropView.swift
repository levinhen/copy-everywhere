import AppKit

/// Transparent overlay view that adds drag-and-drop support to the NSStatusItem button.
/// Returns nil from hitTest so regular clicks pass through to the button underneath,
/// while still receiving drag events (AppKit resolves drag destinations via frame, not hitTest).
final class StatusItemDropView: NSView {
    var onFileDrop: (([URL]) -> Void)?
    var onTextDrop: ((String) -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .string])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragExit?()
        let pasteboard = sender.draggingPasteboard

        // Files take priority over text
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            onFileDrop?(urls)
            return true
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onTextDrop?(text)
            return true
        }

        return false
    }
}
