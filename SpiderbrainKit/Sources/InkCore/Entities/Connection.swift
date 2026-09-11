import Foundation

/// M2 prototype: Connection represents a directed edge in the DAG (from → to).
public struct Connection: Identifiable, Equatable, Codable {
    public let id: UUID
    public let from: UUID  // Source node ID
    public let to: UUID    // Target node ID

    public init(id: UUID = UUID(), from: UUID, to: UUID) {
        self.id = id
        self.from = from
        self.to = to
    }
}
