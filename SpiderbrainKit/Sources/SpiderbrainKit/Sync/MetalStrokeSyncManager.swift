import Foundation

/// Sync manager for Metal ink strokes
public class MetalStrokeSyncManager {
    private var transport: TransportProtocol
    public weak var delegate: MetalStrokeSyncDelegate?

    private var sentStrokes = Set<UUID>()
    private var localDeviceName: String = ""

    public init(transport: TransportProtocol) {
        var mutableTransport = transport
        self.transport = mutableTransport
        self.transport.delegate = self
    }

    /// Send a stroke to all connected peers
    public func sendStroke(_ stroke: Stroke) {
        // Avoid sending duplicates
        guard !sentStrokes.contains(stroke.id) else { return }
        sentStrokes.insert(stroke.id)

        let message = SyncMessage.strokeAdded(stroke)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced stroke \(stroke.id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync stroke: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send stroke deletion to all connected peers
    public func deleteStroke(id: UUID) {
        let message = SyncMessage.strokeDeleted(id: id)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced stroke deletion \(id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync stroke deletion: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send a node to all connected peers
    public func sendNode(_ node: Node) {
        let message = SyncMessage.nodeCreated(node)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced node \(node.id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync node: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send a node creation along with stroke deletions in a single atomic message
    public func sendNodeWithStrokeDeletions(_ node: Node, deletedStrokeIds: [UUID]) {
        let message = SyncMessage.nodeCreatedWithStrokeDeletions(node: node, deletedStrokeIds: deletedStrokeIds)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced node \(node.id) with \(deletedStrokeIds.count) stroke deletions (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync node with deletions: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send node update to all connected peers
    public func updateNode(_ node: Node) {
        let message = SyncMessage.nodeUpdated(node)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced node update \(node.id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync node update: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send node deletion to all connected peers
    public func deleteNode(id: UUID) {
        let message = SyncMessage.nodeDeleted(id: id)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced node deletion \(id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync node deletion: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send a connection to all connected peers
    public func sendConnection(_ connection: Connection) {
        let message = SyncMessage.connectionCreated(connection)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced connection \(connection.id) from \(connection.from) to \(connection.to) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync connection: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Send connection deletion to all connected peers
    public func deleteConnection(id: UUID) {
        let message = SyncMessage.connectionDeleted(id: id)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            try transport.broadcast(data: data)
            print("📤 Synced connection deletion \(id) (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync connection deletion: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    /// Start advertising and browsing
    public func startSync(deviceName: String) throws {
        localDeviceName = deviceName
        try transport.startAdvertising(deviceName: deviceName)
        try transport.startBrowsing()
    }

    /// Stop syncing
    public func stopSync() {
        transport.stopAdvertising()
        transport.stopBrowsing()
    }

    /// Get connected peers
    public var connectedPeers: [PeerDevice] {
        return transport.connectedPeers
    }
}

// MARK: - TransportDelegate

extension MetalStrokeSyncManager: TransportDelegate {
    public func transport(_ transport: TransportProtocol, didDiscover peer: PeerDevice) {
        // Don't connect to ourselves!
        if peer.name == localDeviceName {
            print("⚠️ Discovered ourselves (\(peer.name)), ignoring")
            return
        }

        delegate?.metalStrokeSync(self, didDiscoverPeer: peer)

        // Auto-connect only if not already connected to this peer
        // Check by peer name to avoid duplicate connections over different interfaces
        let alreadyConnected = transport.connectedPeers.contains { connectedPeer in
            connectedPeer.name == peer.name && connectedPeer.id != peer.id
        }

        if alreadyConnected {
            print("⚠️ Already connected to \(peer.name), skipping auto-connect")
            return
        }

        // Auto-connect
        do {
            try transport.connect(to: peer)
            print("🔌 Auto-connecting to \(peer.name)...")
        } catch {
            print("❌ Failed to auto-connect: \(error)")
        }
    }

    public func transport(_ transport: TransportProtocol, didLose peer: PeerDevice) {
        delegate?.metalStrokeSync(self, didLosePeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didChangeState state: TransportState) {
        // State changed
    }

    public func transport(_ transport: TransportProtocol, didConnect peer: PeerDevice) {
        delegate?.metalStrokeSync(self, didConnectToPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didDisconnect peer: PeerDevice, error: Error?) {
        delegate?.metalStrokeSync(self, didDisconnectFromPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didReceive data: Data, from peer: PeerDevice) {
        do {
            let decoder = JSONDecoder()
            let message = try decoder.decode(SyncMessage.self, from: data)

            switch message {
            case .strokeAdded(let stroke):
                print("📥 Received stroke \(stroke.id) from \(peer.name)")
                delegate?.metalStrokeSync(self, didReceiveStroke: stroke, from: peer)

            case .strokeDeleted(let id):
                delegate?.metalStrokeSync(self, didDeleteStroke: id, from: peer)

            case .nodeCreated(let node):
                print("📥 Received node \(node.id) from \(peer.name)")
                delegate?.metalStrokeSync(self, didReceiveNode: node, from: peer)

            case .nodeCreatedWithStrokeDeletions(let node, let deletedStrokeIds):
                print("📥 Received node \(node.id) with \(deletedStrokeIds.count) stroke deletions from \(peer.name)")
                delegate?.metalStrokeSync(self, didReceiveNodeWithStrokeDeletions: node, deletedStrokeIds: deletedStrokeIds, from: peer)

            case .nodeUpdated(let node):
                print("📥 Received node update \(node.id) from \(peer.name)")
                delegate?.metalStrokeSync(self, didUpdateNode: node, from: peer)

            case .nodeDeleted(let id):
                print("📥 Received node deletion \(id) from \(peer.name)")
                delegate?.metalStrokeSync(self, didDeleteNode: id, from: peer)

            case .connectionCreated(let connection):
                print("📥 Received connection \(connection.id) from \(connection.from) to \(connection.to) from \(peer.name)")
                delegate?.metalStrokeSync(self, didReceiveConnection: connection, from: peer)

            case .connectionDeleted(let id):
                print("📥 Received connection deletion \(id) from \(peer.name)")
                delegate?.metalStrokeSync(self, didDeleteConnection: id, from: peer)

            case .fullSync(let strokes):
                delegate?.metalStrokeSync(self, didReceiveFullSync: strokes, from: peer)

            default:
                break
            }
        } catch {
            print("❌ Failed to decode message: \(error)")
            delegate?.metalStrokeSync(self, didEncounterError: error)
        }
    }

    public func transport(_ transport: TransportProtocol, didEncounterError error: Error) {
        delegate?.metalStrokeSync(self, didEncounterError: error)
    }
}

// MARK: - Delegate Protocol

public protocol MetalStrokeSyncDelegate: AnyObject {
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDiscoverPeer peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didLosePeer peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didConnectToPeer peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDisconnectFromPeer peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveStroke stroke: Stroke, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteStroke id: UUID, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveNode node: Node, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveNodeWithStrokeDeletions node: Node, deletedStrokeIds: [UUID], from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didUpdateNode node: Node, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteNode id: UUID, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveConnection connection: Connection, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteConnection id: UUID, from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveFullSync strokes: [Stroke], from peer: PeerDevice)
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didEncounterError error: Error)
}
