import SwiftUI

/// One truthful empty-session presentation shared by Gallery and Grid.
struct SessionEmptyView: View {
    let reason: SessionEmptyReason?
    let canUndo: Bool

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
    }

    private var title: String {
        switch reason {
        case .trashedUndoable:
            return "Everything is in the Trash"
        case .movedOut:
            return "Everything was moved"
        case .unavailableAfterFailedRestore:
            return "No media could be restored"
        case nil:
            return "No media left in this session"
        }
    }

    private var systemImage: String {
        switch reason {
        case .trashedUndoable:
            return "trash"
        case .movedOut:
            return "folder"
        case .unavailableAfterFailedRestore:
            return "exclamationmark.triangle"
        case nil:
            return "photo.on.rectangle.angled"
        }
    }

    private var message: String {
        switch reason {
        case .trashedUndoable where canUndo:
            return "Immediately after Clean Up, press ⌘Z during this open session to restore the items while they remain in the Trash."
        case .trashedUndoable:
            return "The items were moved to the Trash."
        case .movedOut:
            return "The originals are intact in the export destination. Move exports are not undoable."
        case .unavailableAfterFailedRestore:
            return "The items may have been removed from the Trash. Check the source folder and Trash before continuing."
        case nil:
            return "Open or scan the folder again to refresh this session."
        }
    }
}
