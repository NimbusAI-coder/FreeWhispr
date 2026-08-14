import AppKit
import Foundation

/// Puts text into the frontmost app by writing the pasteboard and synthesizing
/// Cmd-V. This is the only reason FreeWhispr ever touches the pasteboard, and the
/// previous contents are put back afterwards.
enum Paster {

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        // Marking the item transient asks clipboard managers not to record it,
        // so dictations do not pile up in clipboard history.
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setString(text, forType: .string)

        sendCommandV()

        guard Settings.restoreClipboard else { return }

        // Give the target app time to read the pasteboard before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restore(saved, to: pasteboard)
        }
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        // 9 is the virtual keycode for "v" on every layout, because CGEvent
        // keycodes are physical positions rather than characters.
        let vKey: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Pasteboard save/restore

    private struct Item {
        let contents: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [Item] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return Item(contents: contents)
        }
    }

    private static func restore(_ items: [Item], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored: [NSPasteboardItem] = items.compactMap { item in
            guard !item.contents.isEmpty else { return nil }
            let new = NSPasteboardItem()
            for (type, data) in item.contents {
                new.setData(data, forType: type)
            }
            return new
        }

        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
