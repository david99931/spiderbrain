import Foundation

/// Manages synchronization of canvas state across devices
public class SyncManager {
    private var transport: TransportProtocol
    public weak var delegate: SyncManagerDelegate?

    public init(transport: TransportProtocol) {
        var mutableTransport = transport
        self.transport = mutableTransport
        self.transport.delegate = self
    }

    // MARK: - Sending Updates

    /// Send a stroke that was just drawn
    public func sendStroke(_ stroke: Stroke) {
        let message = SyncMessage.strokeAdded(stroke)
        broadcast(message)
    }

    /// Send stroke deletion
    public func deleteStroke(id: UUID) {
        let message = SyncMessage.strokeDeleted(id: id)
        broadcast(message)
    }

    /// Send a new node
    public func sendNode(_ node: Node) {
        let message = SyncMessage.nodeCreated(node)
        broadcast(message)
    }

    /// Send node update (position or content changed)
    public func updateNode(_ node: Node) {
        let message = SyncMessage.nodeUpdated(node)
        broadcast(message)
    }

    /// Send node deletion
    public func deleteNode(id: UUID) {
        let message = SyncMessage.nodeDeleted(id: id)
        broadcast(message)
    }

    /// Send correction from ML model
    public func sendCorrection(_ correction: CorrectionData) {
        let message = SyncMessage.correctionApplied(correction)
        broadcast(message)
    }

    /// Send full canvas state (for initial sync)
    public func sendFullSync(_ strokes: [Stroke]) {
        let message = SyncMessage.fullSync(strokes)
        broadcast(message)
    }

    /// Request full sync from connected peers
    public func requestFullSync() {
        let message = SyncMessage.requestFullSync
        broadcast(message)
    }

    // MARK: - Private Helpers

    private func broadcast(_ message: SyncMessage) {
        do {
            let data = try message.encode()
            try transport.broadcast(data: data)
        } catch {
            print("❌ Failed to broadcast sync message: \(error)")
            delegate?.syncManager(self, didEncounterError: error)
        }
    }
}

// MARK: - TransportDelegate

extension SyncManager: TransportDelegate {
    public func transport(_ transport: TransportProtocol, didDiscover peer: PeerDevice) {
        // Notify delegate about new peer
        delegate?.syncManager(self, didDiscoverPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didLose peer: PeerDevice) {
        delegate?.syncManager(self, didLosePeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didChangeState state: TransportState) {
        // Transport state changed
    }

    public func transport(_ transport: TransportProtocol, didConnect peer: PeerDevice) {
        delegate?.syncManager(self, didConnectToPeer: peer)

        // Request full sync when a new peer connects
        requestFullSync()
    }

    public func transport(_ transport: TransportProtocol, didDisconnect peer: PeerDevice, error: Error?) {
        delegate?.syncManager(self, didDisconnectFromPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didReceive data: Data, from peer: PeerDevice) {
        do {
            let message = try SyncMessage.decode(from: data)
            handleSyncMessage(message, from: peer)
        } catch {
            print("❌ Failed to decode sync message: \(error)")
            delegate?.syncManager(self, didEncounterError: error)
        }
    }

    public func transport(_ transport: TransportProtocol, didEncounterError error: Error) {
        delegate?.syncManager(self, didEncounterError: error)
    }

    // MARK: - Message Handling

    private func handleSyncMessage(_ message: SyncMessage, from peer: PeerDevice) {
        switch message {
        case .strokeAdded(let stroke):
            delegate?.syncManager(self, didReceiveStroke: stroke, from: peer)

        case .strokeDeleted(let id):
            delegate?.syncManager(self, didDeleteStroke: id, from: peer)

        case .nodeCreated(let node):
            delegate?.syncManager(self, didReceiveNode: node, from: peer)

        case .nodeCreatedWithStrokeDeletions(let node, _):
            // For the general SyncManager, just handle it as a regular node creation
            delegate?.syncManager(self, didReceiveNode: node, from: peer)

        case .nodeUpdated(let node):
            delegate?.syncManager(self, didUpdateNode: node.id, with: node, from: peer)

        case .nodeDeleted(let id):
            delegate?.syncManager(self, didDeleteNode: id, from: peer)

        case .connectionCreated(_):
            // For the general SyncManager, connections are handled by MetalStrokeSyncManager
            break

        case .connectionDeleted(_):
            // For the general SyncManager, connections are handled by MetalStrokeSyncManager
            break

        case .correctionApplied(let correction):
            delegate?.syncManager(self, didReceiveCorrection: correction, from: peer)

        case .fullSync(let strokes):
            delegate?.syncManager(self, didReceiveFullSync: strokes, from: peer)

        case .requestFullSync:
            delegate?.syncManager(self, didRequestFullSync: peer)
        }
    }
}

// MARK: - Delegate Protocol

public protocol SyncManagerDelegate: AnyObject {
    // Peer lifecycle
    func syncManager(_ manager: SyncManager, didDiscoverPeer peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didLosePeer peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didConnectToPeer peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didDisconnectFromPeer peer: PeerDevice)

    // Stroke events
    func syncManager(_ manager: SyncManager, didReceiveStroke stroke: Stroke, from peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didDeleteStroke id: UUID, from peer: PeerDevice)

    // Node events
    func syncManager(_ manager: SyncManager, didReceiveNode node: Node, from peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didUpdateNode id: UUID, with node: Node, from peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didDeleteNode id: UUID, from peer: PeerDevice)

    // Correction events
    func syncManager(_ manager: SyncManager, didReceiveCorrection correction: CorrectionData, from peer: PeerDevice)

    // Full sync
    func syncManager(_ manager: SyncManager, didReceiveFullSync strokes: [Stroke], from peer: PeerDevice)
    func syncManager(_ manager: SyncManager, didRequestFullSync peer: PeerDevice)

    // Errors
    func syncManager(_ manager: SyncManager, didEncounterError error: Error)
}
