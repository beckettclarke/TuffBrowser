import AppKit
import WebKit

/// Drag and drop for `chrome.debugger` (see `ExtensionDebugger`): a page's drag as CDP's
/// `DragData`, and back onto a pasteboard to play it into a web view with a stand-in
/// `NSDraggingInfo`, as AppKit would during a real drag.
enum ExtensionDebuggerDrag {
    /// Pasteboard types that have a MIME type of their own; any other type travels as
    /// `application/x-tuff-pasteboard;type=<type>` with its bytes in base64 (WebKit keeps a page's
    /// own `DataTransfer` types in one such type), so it comes back exactly.
    private static let mimeTypes: [NSPasteboard.PasteboardType: String] = [
        .string: "text/plain", .html: "text/html", .URL: "text/uri-list",
    ]
    private static let rawPrefix = "application/x-tuff-pasteboard;type="

    static func dragData(from pasteboard: NSPasteboard, mask: NSDragOperation) -> [String: Any] {
        var items: [[String: Any]] = []
        for type in pasteboard.types ?? [] {
            if let mime = mimeTypes[type] {
                guard let text = pasteboard.string(forType: type) else { continue }
                items.append(["mimeType": mime, "data": text])
            } else if let data = pasteboard.data(forType: type) {
                items.append(["mimeType": rawPrefix + type.rawValue, "data": data.base64EncodedString()])
            }
        }
        return ["items": items, "dragOperationsMask": Int(mask.rawValue)]
    }

    /// A private pasteboard holding `DragData`.
    static func pasteboard(with dragData: [String: Any]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TuffDebuggerDrag"))
        pasteboard.clearContents()
        var values: [(NSPasteboard.PasteboardType, Any)] = []
        for item in dragData["items"] as? [[String: Any]] ?? [] {
            guard let mime = item["mimeType"] as? String, let data = item["data"] as? String else { continue }
            if mime.hasPrefix(rawPrefix) {
                if let bytes = Data(base64Encoded: data) { values.append((NSPasteboard.PasteboardType(String(mime.dropFirst(rawPrefix.count))), bytes)) }
            } else if let type = mimeTypes.first(where: { $0.value == mime.lowercased() })?.key {
                values.append((type, data))
            } else {
                values.append((NSPasteboard.PasteboardType(mime), Data(data.utf8)))
            }
        }
        pasteboard.declareTypes(values.map(\.0), owner: nil)
        for (type, value) in values {
            if let text = value as? String { pasteboard.setString(text, forType: type) } else if let data = value as? Data { pasteboard.setData(data, forType: type) }
        }
        return pasteboard
    }

    /// Something to hand WebKit in place of a drag session that never started.
    static func placeholderSession() -> NSDraggingSession {
        (NSClassFromString("NSDraggingSession") as! NSObject.Type).init() as! NSDraggingSession
    }

    /// Tells the page's side that its drag is over (its `dragend`).
    static func end(_ source: NSDraggingSource, _ session: NSDraggingSession, at point: NSPoint, operation: NSDragOperation) {
        source.draggingSession?(session, endedAt: point, operation: operation)
    }

    /// What AppKit tells a drop target during a drag, made up for a played-back one.
    final class DraggingInfo: NSObject, NSDraggingInfo {
        private let pasteboard: NSPasteboard
        private let location: NSPoint
        private weak var window: NSWindow?
        private let mask: NSDragOperation

        init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow, mask: NSDragOperation) {
            self.pasteboard = pasteboard
            self.location = location
            self.window = window
            self.mask = mask
        }

        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { mask }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }
}
