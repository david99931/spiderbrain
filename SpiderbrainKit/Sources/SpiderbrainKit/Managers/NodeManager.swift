import Foundation

/// Manages node CRUD operations
public class NodeManager {
    private var nodes: [Node] = []

    /// Get all nodes
    public var allNodes: [Node] {
        return nodes
    }

    /// Add a new node
    public func addNode(_ node: Node) {
        nodes.append(node)
    }

    /// Add a received node from sync
    /// Returns true if added, false if duplicate
    public func addReceivedNode(_ node: Node) -> Bool {
        // Check if node already exists (avoid duplicates)
        guard !nodes.contains(where: { $0.id == node.id }) else { return false }
        nodes.append(node)
        return true
    }

    /// Update an existing node
    /// Returns true if updated, false if not found
    public func updateNode(_ node: Node) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return false }
        nodes[index] = node
        return true
    }

    /// Delete a node by ID
    /// Returns the deleted node if found, nil otherwise
    public func deleteNode(id: UUID) -> Node? {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return nil }
        let node = nodes[index]
        nodes.remove(at: index)
        return node
    }

    /// Find a node by ID
    public func node(withId id: UUID) -> Node? {
        return nodes.first(where: { $0.id == id })
    }

    /// Find node at a specific point
    public func node(at point: Vec2) -> Node? {
        // Check in reverse order (topmost first)
        for node in nodes.reversed() {
            if node.bounds.contains(point) {
                return node
            }
        }
        return nil
    }

    /// Find node index by ID
    public func nodeIndex(withId id: UUID) -> Int? {
        return nodes.firstIndex(where: { $0.id == id })
    }

    /// Update node's connections array
    /// Returns true if updated, false if node not found
    public func updateNodeConnections(nodeId: UUID, connections: [UUID]) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else { return false }
        nodes[index].connections = connections
        return true
    }

    /// Add a connection target to a node's connections array
    /// Returns true if added, false if node not found or already contains target
    public func addConnectionToNode(nodeId: UUID, targetId: UUID) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else { return false }
        if nodes[index].connections.contains(targetId) { return false }
        nodes[index].connections.append(targetId)
        return true
    }

    /// Remove a connection target from a node's connections array
    /// Returns true if removed, false if node not found
    public func removeConnectionFromNode(nodeId: UUID, targetId: UUID) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else { return false }
        nodes[index].connections.removeAll { $0 == targetId }
        return true
    }

    /// Remove a specific node ID from ALL nodes' connections arrays
    public func removeNodeFromAllConnections(nodeId: UUID) {
        for i in nodes.indices {
            nodes[i].connections.removeAll { $0 == nodeId }
        }
    }
}
