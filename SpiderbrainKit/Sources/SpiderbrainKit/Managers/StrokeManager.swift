import Foundation

/// Manages stroke CRUD operations
public class StrokeManager {
    private var strokes: [Stroke] = []

    /// Get all strokes
    public var allStrokes: [Stroke] {
        return strokes
    }

    /// Add a new stroke
    public func addStroke(_ stroke: Stroke) {
        strokes.append(stroke)
    }

    /// Add a received stroke from sync
    /// Returns true if added, false if duplicate
    public func addReceivedStroke(_ stroke: Stroke) -> Bool {
        // Check if stroke already exists (avoid duplicates)
        guard !strokes.contains(where: { $0.id == stroke.id }) else { return false }
        strokes.append(stroke)
        return true
    }

    /// Delete a stroke by ID
    /// Returns the deleted stroke if found, nil otherwise
    public func deleteStroke(id: UUID) -> Stroke? {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let stroke = strokes[index]
        strokes.remove(at: index)
        return stroke
    }

    /// Delete a stroke at a specific index
    /// Returns the deleted stroke if found, nil otherwise
    public func deleteStroke(at index: Int) -> Stroke? {
        guard index >= 0 && index < strokes.count else { return nil }
        let stroke = strokes[index]
        strokes.remove(at: index)
        return stroke
    }

    /// Delete multiple strokes by indices
    /// Returns the deleted strokes
    /// IMPORTANT: indices must be in descending order to avoid index shifting
    public func deleteStrokes(at indices: [Int]) -> [Stroke] {
        var deleted: [Stroke] = []
        for i in indices.sorted(by: >) {
            if i >= 0 && i < strokes.count {
                deleted.append(strokes[i])
                strokes.remove(at: i)
            }
        }
        return deleted.reversed() // Return in original order
    }

    /// Find a stroke by ID
    public func stroke(withId id: UUID) -> Stroke? {
        return strokes.first(where: { $0.id == id })
    }

    /// Find stroke index by ID
    public func strokeIndex(withId id: UUID) -> Int? {
        return strokes.firstIndex(where: { $0.id == id })
    }

    /// Find stroke at a specific index
    public func stroke(at index: Int) -> Stroke? {
        guard index >= 0 && index < strokes.count else { return nil }
        return strokes[index]
    }

    /// Replace all strokes (used for full sync)
    public func replaceAllStrokes(_ newStrokes: [Stroke]) {
        strokes = newStrokes
    }

    /// Clear all strokes
    public func clearAll() {
        strokes.removeAll()
    }

    /// Count of strokes
    public var count: Int {
        return strokes.count
    }
}
