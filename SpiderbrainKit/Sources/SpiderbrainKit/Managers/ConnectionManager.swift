import Foundation

/// Manages connections between nodes (directed edges in the DAG)
public class ConnectionManager {
    private var connections: [Connection] = []

    /// Get all connections
    public var allConnections: [Connection] {
        return connections
    }

    /// Add a connection from one node to another
    /// Returns the created connection if successful, nil if rejected
    /// Rejects self-loops (from == to) and duplicate connections
    public func addConnection(from sourceId: UUID, to targetId: UUID, nodes: [Node]) -> Connection? {
        // Reject self-loops
        guard sourceId != targetId else { return nil }

        // Reject if connection already exists
        if connections.contains(where: { $0.from == sourceId && $0.to == targetId }) {
            return nil
        }

        // Verify both nodes exist
        guard nodes.contains(where: { $0.id == sourceId }),
              nodes.contains(where: { $0.id == targetId }) else {
            return nil
        }

        // Create and store connection
        let connection = Connection(from: sourceId, to: targetId)
        connections.append(connection)

        return connection
    }

    /// Add a connection received from sync (with existing ID)
    /// Returns true if added, false if duplicate
    public func addReceivedConnection(_ connection: Connection, nodes: [Node]) -> Bool {
        // Don't add if it already exists
        guard !connections.contains(where: { $0.id == connection.id }) else { return false }

        // Verify both nodes exist
        guard nodes.contains(where: { $0.id == connection.from }),
              nodes.contains(where: { $0.id == connection.to }) else {
            return false
        }

        connections.append(connection)
        return true
    }

    /// Remove a connection by ID
    /// Returns the removed connection if found, nil otherwise
    public func removeConnection(id: UUID) -> Connection? {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return nil }
        let connection = connections[index]
        connections.remove(at: index)
        return connection
    }

    /// Remove all connections to/from a specific node
    /// Returns the removed connections
    public func removeAllConnections(for nodeId: UUID) -> [Connection] {
        let removed = connections.filter { $0.from == nodeId || $0.to == nodeId }
        connections.removeAll { $0.from == nodeId || $0.to == nodeId }
        return removed
    }

    /// Get all outgoing connections from a node
    public func outgoingConnections(from nodeId: UUID) -> [Connection] {
        return connections.filter { $0.from == nodeId }
    }

    /// Get all incoming connections to a node
    public func incomingConnections(to nodeId: UUID) -> [Connection] {
        return connections.filter { $0.to == nodeId }
    }

    /// Check if a connection exists between two nodes
    public func connectionExists(from sourceId: UUID, to targetId: UUID) -> Bool {
        return connections.contains(where: { $0.from == sourceId && $0.to == targetId })
    }

    /// Find connection by ID
    public func connection(withId id: UUID) -> Connection? {
        return connections.first(where: { $0.id == id })
    }
}
