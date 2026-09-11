import Foundation

/// Protocol that all transport implementations must conform to
/// This allows swapping between Bonjour, WebSocket, CloudKit, etc.
public protocol TransportProtocol {
    /// Unique identifier for this transport instance
    var id: UUID { get }

    /// Current connection state
    var state: TransportState { get }

    /// Delegate to receive transport events
    var delegate: TransportDelegate? { get set }

    /// Start advertising this device as available for connection
    func startAdvertising(deviceName: String) throws

    /// Stop advertising
    func stopAdvertising()

    /// Start browsing for other devices
    func startBrowsing() throws

    /// Stop browsing
    func stopBrowsing()

    /// Connect to a discovered peer
    func connect(to peer: PeerDevice) throws

    /// Disconnect from a peer
    func disconnect(from peer: PeerDevice)

    /// Send data to a specific peer
    func send(data: Data, to peer: PeerDevice) throws

    /// Send data to all connected peers
    func broadcast(data: Data) throws

    /// Get list of currently connected peers
    var connectedPeers: [PeerDevice] { get }

    /// Get list of discovered but not connected peers
    var availablePeers: [PeerDevice] { get }
}

/// Transport connection state
public enum TransportState: Equatable {
    case disconnected
    case advertising
    case browsing
    case connecting
    case connected
}

/// Represents a peer device
public struct PeerDevice: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let platform: DevicePlatform

    public init(id: UUID, name: String, platform: DevicePlatform) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

/// Platform type for peer device
public enum DevicePlatform: String, Codable {
    case iOS
    case macOS
    case unknown
}

/// Delegate protocol for transport events
public protocol TransportDelegate: AnyObject {
    /// Called when a new peer is discovered
    func transport(_ transport: TransportProtocol, didDiscover peer: PeerDevice)

    /// Called when a peer is lost (no longer available)
    func transport(_ transport: TransportProtocol, didLose peer: PeerDevice)

    /// Called when connection state changes
    func transport(_ transport: TransportProtocol, didChangeState state: TransportState)

    /// Called when a peer connects
    func transport(_ transport: TransportProtocol, didConnect peer: PeerDevice)

    /// Called when a peer disconnects
    func transport(_ transport: TransportProtocol, didDisconnect peer: PeerDevice, error: Error?)

    /// Called when data is received from a peer
    func transport(_ transport: TransportProtocol, didReceive data: Data, from peer: PeerDevice)

    /// Called when an error occurs
    func transport(_ transport: TransportProtocol, didEncounterError error: Error)
}
