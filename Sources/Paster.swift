import AppKit
import Foundation

/// Puts text into the frontmost app by writing the pasteboard and synthesizing
/// Cmd-V. This is the only reason FreeWhispr ever touches the pasteboard, and the
/// previous contents are put back afterwards.
@MainActor
enum Paster {

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The user's true pre-dictation clipboard while a restore is pending.
    /// A chained paste arriving before the previous restore fires must carry
    /// this forward — snapshotting at that moment would capture the previous
    /// *transcript* and "restore" it over the user's real clipboard.
    private static var pendingSaved: [Item]?

    /// changeCount of the most recent write made by us, so a skipped restore
    /// can tell "a newer dictation pasted" from "the user copied something".
    private static var lastOwnCount = -1

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let restoring = Settings.restoreClipboard
        let saved = restoring ? (pendingSaved ?? snapshot(of: pasteboard)) : []

        pasteboard.clearContents()
        // Marking the item transient asks clipboard managers not to record it,
        // so dictations do not pile up in clipboard history.
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setString(text, forType: .string)
        let myCount = pasteboard.changeCount

        sendCommandV()

        guard restoring else {
            pendingSaved = nil
            return
        }
        lastOwnCount = myCount
        pendingSaved = saved

        // Give the target app time to read the pasteboard before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Restore only while still owning the pasteboard. A restore firing
            // after a newer dictation's paste would hand the target app the
            // pre-dictation clipboard instead of the words just dictated.
            guard pasteboard.changeCount == myCount else {
                // If the newer write wasn't ours, the user copied something —
                // the saved chain is obsolete and must not resurface later.
                if pasteboard.changeCount != lastOwnCount { pendingSaved = nil }
                return
            }
            pendingSaved = nil
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
