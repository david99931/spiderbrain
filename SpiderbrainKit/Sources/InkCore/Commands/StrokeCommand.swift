import Foundation

/// A requested mutation to the stroke collection.
///
/// Commands are data, not calls: they can be logged, replayed, and tested without
/// a view, a GPU, or a network. Every stroke mutation in the app is expressed as
/// one of these and applied by `StrokeCommandExecutor`.
public enum StrokeCommand: Equatable {
    /// Add a stroke. Ignored if a stroke with the same id is already present.
    case add(Stroke)

    /// Delete one stroke by id. Ignored if not present.
    case delete(id: UUID)

    /// Delete several strokes by id in a single operation.
    ///
    /// Distinct from repeated `delete` because callers that fold stroke removal
    /// into a larger atomic message (node creation, for example) need the whole
    /// set to land as one effect rather than a sequence of separate ones.
    case deleteMany(ids: [UUID])

    /// Remove the most recently added stroke. No-op when empty.
    case removeLast

    /// Remove every stroke.
    case clear
}
