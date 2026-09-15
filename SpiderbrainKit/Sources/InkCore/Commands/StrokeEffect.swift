import Foundation

/// What actually changed as a result of executing a command.
///
/// The executor reports effects rather than performing side effects itself, so it
/// stays free of rendering and networking. Callers interpret effects: the view
/// rebuilds geometry, the sync layer broadcasts. An effect is only emitted when
/// state genuinely changed — a no-op command yields none.
public enum StrokeEffect: Equatable {
    /// A stroke was added.
    case added(Stroke)

    /// Strokes were removed. Carries ids because the strokes no longer exist.
    case removed(ids: [UUID])

    /// The collection changed wholesale; incremental geometry updates don't apply.
    case clearedAll
}
