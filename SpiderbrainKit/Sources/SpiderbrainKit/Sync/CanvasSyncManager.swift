import Foundation
import PencilKit

/// Simplified sync manager for canvas collaboration
/// Syncs entire PKDrawing updates for now (can optimize to individual strokes later)
public class CanvasSyncManager {
    private var transport: TransportProtocol
    public weak var delegate: CanvasSyncDelegate?

    private var lastSentDrawing: PKDrawing?
    private var isSyncing = false

    public init(transport: TransportProtocol) {
        var mutableTransport = transport
        self.transport = mutableTransport
        self.transport.delegate = self
    }

    /// Send current drawing to all connected peers
    public func syncDrawing(_ drawing: PKDrawing) {
        // Avoid sending the same drawing multiple times
        guard drawing.dataRepresentation() != lastSentDrawing?.dataRepresentation() else {
            return
        }

        let message = DrawingSyncMessage(drawing: drawing)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)

            try transport.broadcast(data: data)
            lastSentDrawing = drawing
            print("📤 Synced drawing (\(data.count) bytes)")
        } catch {
            print("❌ Failed to sync drawing: \(error)")
            delegate?.canvasSync(self, didEncounterError: error)
        }
    }

    /// Start advertising and browsing
    public func startSync(deviceName: String) throws {
        try transport.startAdvertising(deviceName: deviceName)
        try transport.startBrowsing()
    }

    /// Stop syncing
    public func stopSync() {
        transport.stopAdvertising()
        transport.stopBrowsing()
    }

    /// Connect to a discovered peer
    public func connect(to peer: PeerDevice) throws {
        try transport.connect(to: peer)
    }

    /// Get available peers
    public var availablePeers: [PeerDevice] {
        return transport.availablePeers
    }

    /// Get connected peers
    public var connectedPeers: [PeerDevice] {
        return transport.connectedPeers
    }
}

// MARK: - TransportDelegate

extension CanvasSyncManager: TransportDelegate {
    public func transport(_ transport: TransportProtocol, didDiscover peer: PeerDevice) {
        delegate?.canvasSync(self, didDiscoverPeer: peer)

        // Auto-connect to discovered peers
        do {
            try transport.connect(to: peer)
            print("🔌 Auto-connecting to \(peer.name)...")
        } catch {
            print("❌ Failed to auto-connect to \(peer.name): \(error)")
        }
    }

    public func transport(_ transport: TransportProtocol, didLose peer: PeerDevice) {
        delegate?.canvasSync(self, didLosePeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didChangeState state: TransportState) {
        // State changed
    }

    public func transport(_ transport: TransportProtocol, didConnect peer: PeerDevice) {
        delegate?.canvasSync(self, didConnectToPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didDisconnect peer: PeerDevice, error: Error?) {
        delegate?.canvasSync(self, didDisconnectFromPeer: peer)
    }

    public func transport(_ transport: TransportProtocol, didReceive data: Data, from peer: PeerDevice) {
        // Don't process messages we're currently sending to avoid loops
        guard !isSyncing else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(DrawingSyncMessage.self, from: data)
            let drawing = try message.toDrawing()

            print("📥 Received drawing from \(peer.name) (\(data.count) bytes)")

            isSyncing = true
            delegate?.canvasSync(self, didReceiveDrawing: drawing, from: peer)
            isSyncing = false
        } catch {
            print("❌ Failed to decode drawing: \(error)")
            delegate?.canvasSync(self, didEncounterError: error)
        }
    }

    public func transport(_ transport: TransportProtocol, didEncounterError error: Error) {
        delegate?.canvasSync(self, didEncounterError: error)
    }
}

// MARK: - Delegate Protocol

public protocol CanvasSyncDelegate: AnyObject {
    func canvasSync(_ manager: CanvasSyncManager, didDiscoverPeer peer: PeerDevice)
    func canvasSync(_ manager: CanvasSyncManager, didLosePeer peer: PeerDevice)
    func canvasSync(_ manager: CanvasSyncManager, didConnectToPeer peer: PeerDevice)
    func canvasSync(_ manager: CanvasSyncManager, didDisconnectFromPeer peer: PeerDevice)
    func canvasSync(_ manager: CanvasSyncManager, didReceiveDrawing drawing: PKDrawing, from peer: PeerDevice)
    func canvasSync(_ manager: CanvasSyncManager, didEncounterError error: Error)
}
