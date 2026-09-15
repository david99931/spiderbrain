import Foundation

/// Owns the stroke collection and is the only thing permitted to mutate it.
///
/// Every stroke mutation funnels through `execute`, which returns the effects that
/// actually occurred. Two invariants come for free as a result:
///
/// - **No duplicates.** `add` is idempotent by stroke id, so a stroke arriving over
///   several peer connections lands once.
/// - **No phantom deletes.** Removal effects only ever name ids that were really
///   present, so a caller passing a stale or repeated id cannot produce a deletion
///   for a stroke that isn't there.
///
/// The executor performs no side effects: it neither renders nor broadcasts. It
/// reports what changed and lets callers decide what that means.
public final class StrokeCommandExecutor {

    private var storage: [Stroke] = []

    public init(strokes: [Stroke] = []) {
        self.storage = strokes
    }

    /// The current strokes, in insertion order.
    public var strokes: [Stroke] { storage }

    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    public func stroke(withId id: UUID) -> Stroke? {
        storage.first { $0.id == id }
    }

    public func contains(id: UUID) -> Bool {
        storage.contains { $0.id == id }
    }

    /// Apply a command and report what changed.
    ///
    /// Returns an empty array when the command was a no-op, which callers can use to
    /// skip redundant redraws and avoid broadcasting nothing.
    ///
    /// - Parameters:
    ///   - command: the mutation to apply.
    ///   - origin: where it came from. The executor does not itself broadcast; origin
    ///     is returned to the caller's decision-making unchanged, and is accepted here
    ///     so the full command record is available for logging and future replay.
    @discardableResult
    public func execute(_ command: StrokeCommand, origin: CommandOrigin) -> [StrokeEffect] {
        switch command {
        case .add(let stroke):
            guard !contains(id: stroke.id) else { return [] }
            storage.append(stroke)
            return [.added(stroke)]

        case .delete(let id):
            guard let index = storage.firstIndex(where: { $0.id == id }) else { return [] }
            storage.remove(at: index)
            return [.removed(ids: [id])]

        case .deleteMany(let ids):
            // Only report ids that were genuinely present, deduplicated. A caller
            // passing the same id repeatedly cannot produce repeated deletions.
            var seen = Set<UUID>()
            var actuallyRemoved: [UUID] = []
            for id in ids where !seen.contains(id) {
                seen.insert(id)
                if contains(id: id) {
                    actuallyRemoved.append(id)
                }
            }
            guard !actuallyRemoved.isEmpty else { return [] }
            let removalSet = Set(actuallyRemoved)
            storage.removeAll { removalSet.contains($0.id) }
            return [.removed(ids: actuallyRemoved)]

        case .removeLast:
            guard let last = storage.popLast() else { return [] }
            return [.removed(ids: [last.id])]

        case .clear:
            guard !storage.isEmpty else { return [] }
            storage.removeAll()
            return [.clearedAll]
        }
    }

    /// Replace the entire collection without emitting effects.
    ///
    /// For bulk load and full-sync paths, where the caller rebuilds all downstream
    /// state anyway and per-stroke effects would be noise.
    public func replaceAll(_ strokes: [Stroke]) {
        storage = strokes
    }
}
