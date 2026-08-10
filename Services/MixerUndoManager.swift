import Foundation
import Observation
import AppKit

/// Undo for mixer changes.
///
/// Apple's second design principle is agency, and it names forgiveness as
/// what backs it: people will only explore controls they can retreat from.
/// A mixer without undo punishes the one thing it should encourage —
/// dragging a fader to hear what happens.
///
/// Coalescing matters as much as the stack. A slider drag emits a change
/// per pixel; registering each one would make ⌘Z step back through a
/// hundred imperceptible states instead of the move the user made. Changes
/// to the same control within `coalescingWindow` collapse into one.
@MainActor
@Observable
public final class MixerUndoManager {
    public static let shared = MixerUndoManager()

    /// What a single undoable change looked like before and after.
    private struct Entry {
        let bundleID: String
        let label: String
        let undo: () -> Void
        let redo: () -> Void
        /// Identifies the control, so consecutive edits to it can merge.
        let coalescingKey: String
        let timestamp: Date
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    private static let depth = 50
    private static let coalescingWindow: TimeInterval = 0.8

    /// Exposed so menu items can disable themselves rather than silently
    /// doing nothing.
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var undoLabel: String?
    public private(set) var redoLabel: String?

    private init() {}

    // MARK: - Recording

    /// Records a change. `label` appears in the menu ("Undo Spotify Volume").
    public func record(
        bundleID: String,
        control: String,
        label: String,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void
    ) {
        let key = "\(bundleID)#\(control)"
        let now = Date()

        // Merge with the previous entry when it is the same control being
        // moved continuously: keep the *original* undo (so one ⌘Z returns to
        // where the drag started) and take the newest redo.
        if let last = undoStack.last,
           last.coalescingKey == key,
           now.timeIntervalSince(last.timestamp) < Self.coalescingWindow {
            undoStack[undoStack.count - 1] = Entry(
                bundleID: bundleID,
                label: label,
                undo: last.undo,
                redo: redo,
                coalescingKey: key,
                timestamp: now
            )
        } else {
            undoStack.append(Entry(
                bundleID: bundleID,
                label: label,
                undo: undo,
                redo: redo,
                coalescingKey: key,
                timestamp: now
            ))
            if undoStack.count > Self.depth {
                undoStack.removeFirst(undoStack.count - Self.depth)
            }
        }

        // Any new edit invalidates the redo branch, as everywhere else.
        redoStack.removeAll()
        refresh()
    }

    /// Records one change made up of many — applying a preset, routing
    /// every app at once — as a single step.
    ///
    /// Without this, applying a preset over ten apps pushed ten separate
    /// entries and ⌘Z unwound it one application at a time, which is not
    /// what anybody means by undoing "apply preset".
    public func recordTransaction(
        label: String,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void
    ) {
        undoStack.append(Entry(
            bundleID: "",
            label: label,
            undo: undo,
            redo: redo,
            // A unique key, so a transaction never merges into a
            // neighbouring one the way slider drags do.
            coalescingKey: UUID().uuidString,
            timestamp: Date()
        ))
        if undoStack.count > Self.depth {
            undoStack.removeFirst(undoStack.count - Self.depth)
        }
        redoStack.removeAll()
        refresh()
    }

    // MARK: - Performing

    public func performUndo() {
        guard let entry = undoStack.popLast() else { return }
        entry.undo()
        redoStack.append(entry)
        refresh()
    }

    public func performRedo() {
        guard let entry = redoStack.popLast() else { return }
        entry.redo()
        undoStack.append(entry)
        refresh()
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        refresh()
    }

    private func refresh() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoLabel = undoStack.last?.label
        redoLabel = redoStack.last?.label
    }
}
