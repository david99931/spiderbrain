import Foundation
import Network

/// Bonjour-based transport using Apple's Network.framework
/// Supports local network discovery and communication
public class BonjourTransport: TransportProtocol {
    public let id = UUID()
    public private(set) var state: TransportState = .disconnected
    public weak var delegate: TransportDelegate?

    private let serviceType = "_spiderbrain._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [UUID: PeerConnection] = [:]
    private var discoveredPeers: [UUID: PeerDevice] = [:]
    private var deviceName: String = ""

    // Track rejected incoming connections to throttle logging
    private var rejectedConnectionCount = 0
    private var lastRejectionLogTime: Date?

    private let queue = DispatchQueue(label: "com.spiderbrain.bonjour", qos: .userInitiated)

    public init() {}

    // MARK: - Advertising

    public func startAdvertising(deviceName: String) throws {
        guard listener == nil else {
            print("⚠️ Already advertising")
            return
        }

        self.deviceName = deviceName

        do {
            // Create TCP listener
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener

            // Determine current platform
            #if os(iOS)
            let platformString = "iOS"
            #elseif os(macOS)
            let platformString = "macOS"
            #else
            let platformString = "unknown"
            #endif

            // Create TXT record with platform info
            let txtRecord = NWTXTRecord(["platform": platformString])

            // Set Bonjour service with TXT record
            listener.service = NWListener.Service(name: deviceName, type: serviceType, txtRecord: txtRecord)

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerStateChange(state)
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            listener.start(queue: queue)
            updateState(.advertising)

            print("✅ Started advertising as \"\(deviceName)\"")

        } catch {
            throw TransportError.advertisingFailed(error)
        }
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
        if state == .advertising && browser == nil {
            updateState(.disconnected)
        }
        print("🛑 Stopped advertising")
    }

    // MARK: - Browsing

    public func startBrowsing() throws {
        guard browser == nil else {
            print("⚠️ Already browsing")
            return
        }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserStateChange(state)
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResultsChanged(results: results, changes: changes)
        }

        browser.start(queue: queue)
        updateState(.browsing)

        print("🔍 Started browsing for peers")
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        if state == .browsing && listener == nil {
            updateState(.disconnected)
        }
        print("🛑 Stopped browsing")
    }

    // MARK: - Connection Management

    public func connect(to peer: PeerDevice) throws {
        // Check if already connected to this peer
        if connections[peer.id] != nil {
            print("⚠️ Already connected to peer \(peer.name) (id: \(peer.id)), skipping")
            return
        }

        // Check if already connected to a peer with the same name (different interface)
        if connections.values.contains(where: { $0.peer.name == peer.name }) {
            print("⚠️ Already connected to \(peer.name) via different interface, skipping")
            return
        }

        // Find the browse result for this peer
        guard let browseResult = findBrowseResult(for: peer) else {
            throw TransportError.peerNotFound
        }

        // Create connection
        let connection = NWConnection(to: browseResult.endpoint, using: .tcp)
        setupConnection(connection, peer: peer)
        connection.start(queue: queue)

        print("🔌 Connecting to \(peer.name)...")
    }

    public func disconnect(from peer: PeerDevice) {
        if let peerConnection = connections[peer.id] {
            peerConnection.connection.cancel()
            connections.removeValue(forKey: peer.id)
            delegate?.transport(self, didDisconnect: peer, error: nil)
            print("🔌 Disconnected from \(peer.name)")
        }
    }

    // MARK: - Data Transmission

    public func send(data: Data, to peer: PeerDevice) throws {
        guard let peerConnection = connections[peer.id] else {
            throw TransportError.notConnected
        }

        sendData(data, on: peerConnection.connection)
    }

    public func broadcast(data: Data) throws {
        for connection in connections.values {
            sendData(data, on: connection.connection)
        }
    }

    // MARK: - Peer Lists

    public var connectedPeers: [PeerDevice] {
        connections.values.map { $0.peer }
    }

    public var availablePeers: [PeerDevice] {
        Array(discoveredPeers.values)
    }

    // MARK: - Private Helpers

    /// Log connection rejections with throttling to avoid log spam
    private func logRejection(_ message: String) {
        let now = Date()

        // Reset counter if it's been more than 10 seconds since last rejection
        if let lastTime = lastRejectionLogTime, now.timeIntervalSince(lastTime) > 10 {
            rejectedConnectionCount = 0
        }

        rejectedConnectionCount += 1
        lastRejectionLogTime = now

        // Only log the first 3 rejections, then one summary every 20 rejections
        if rejectedConnectionCount <= 3 {
            print("⚠️ \(message)")
        } else if rejectedConnectionCount % 20 == 0 {
            print("⚠️ (\(rejectedConnectionCount) connection attempts rejected)")
        }
    }

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("✅ Listener ready on port \(listener?.port?.debugDescription ?? "unknown")")
        case .failed(let error):
            print("❌ Listener failed: \(error)")
            delegate?.transport(self, didEncounterError: TransportError.listenerFailed(error))
            listener?.cancel()
            listener = nil
        case .cancelled:
            print("🛑 Listener cancelled")
        default:
            break
        }
    }

    private func handleBrowserStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            print("✅ Browser ready")
        case .failed(let error):
            print("❌ Browser failed: \(error)")
            delegate?.transport(self, didEncounterError: TransportError.browserFailed(error))
            browser?.cancel()
            browser = nil
        case .cancelled:
            print("🛑 Browser cancelled")
        default:
            break
        }
    }

    private func handleBrowseResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handlePeerDiscovered(result)
            case .removed(let result):
                handlePeerLost(result)
            default:
                break
            }
        }
    }

    private func handlePeerDiscovered(_ result: NWBrowser.Result) {
        // Extract peer info from endpoint
        if case .service(let name, _, _, let txtRecord) = result.endpoint {
            // Generate a deterministic ID from the service name using hash
            let peerId = UUID(uuid: name.utf8.withContiguousStorageIfAvailable { bytes in
                var hasher = (0..<16).map { _ in UInt8(0) }
                for (index, byte) in bytes.prefix(16).enumerated() {
                    hasher[index] = byte
                }
                return uuid_t(
                    hasher[0], hasher[1], hasher[2], hasher[3],
                    hasher[4], hasher[5], hasher[6], hasher[7],
                    hasher[8], hasher[9], hasher[10], hasher[11],
                    hasher[12], hasher[13], hasher[14], hasher[15]
                )
            } ?? uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))

            // Extract platform from device name suffix
            var platform: DevicePlatform = .unknown
            if name.hasSuffix("-iOS") {
                platform = .iOS
            } else if name.hasSuffix("-Mac") {
                platform = .macOS
            }

            let peer = PeerDevice(id: peerId, name: name, platform: platform)
            discoveredPeers[peer.id] = peer

            delegate?.transport(self, didDiscover: peer)
            print("👋 Discovered peer: \(peer.name) (\(platform))")
        }
    }

    private func handlePeerLost(_ result: NWBrowser.Result) {
        // Find and remove from discovered peers
        if case .service(let name, _, _, _) = result.endpoint {
            // Use same deterministic ID generation as discovery
            let peerId = UUID(uuid: name.utf8.withContiguousStorageIfAvailable { bytes in
                var hasher = (0..<16).map { _ in UInt8(0) }
                for (index, byte) in bytes.prefix(16).enumerated() {
                    hasher[index] = byte
                }
                return uuid_t(
                    hasher[0], hasher[1], hasher[2], hasher[3],
                    hasher[4], hasher[5], hasher[6], hasher[7],
                    hasher[8], hasher[9], hasher[10], hasher[11],
                    hasher[12], hasher[13], hasher[14], hasher[15]
                )
            } ?? uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))

            if let peer = discoveredPeers.removeValue(forKey: peerId) {
                delegate?.transport(self, didLose: peer)
                print("👋 Lost peer: \(peer.name)")
            }
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        print("📞 Incoming connection from \(connection.endpoint)")

        // For incoming connections, try to match with discovered peers
        // Since we don't have the service name in the endpoint, we'll create a temporary peer
        // and update it when we receive the first message

        // Check if this connection matches any discovered peer by trying all of them
        var matchedPeer: PeerDevice?
        for (_, discoveredPeer) in discoveredPeers {
            // Try to connect and see if it's the same peer
            // For now, we'll use the first discovered peer as a fallback
            if matchedPeer == nil {
                matchedPeer = discoveredPeer
            }
        }

        // If we found a discovered peer, use that; otherwise create an unknown peer
        let peer: PeerDevice
        if let matched = matchedPeer, discoveredPeers.count == 1 {
            // Only use the matched peer if there's exactly one discovered peer

            // Check if already connected to this peer
            if connections[matched.id] != nil {
                logRejection("Already connected to \(matched.name), rejecting incoming connection")
                connection.cancel()
                return
            }

            peer = matched
            print("📞 Matched incoming connection to discovered peer: \(matched.name)")
        } else {
            // If we already have connections, reject additional unknown connections
            if !connections.isEmpty {
                logRejection("Already have active connections, rejecting unknown incoming connection")
                connection.cancel()
                return
            }

            // Create a temporary unknown peer - we'll update it later if needed
            let tempId = UUID()
            peer = PeerDevice(id: tempId, name: "Unknown", platform: .unknown)
            print("📞 Creating temporary peer for incoming connection")
        }

        setupConnection(connection, peer: peer)
        connection.start(queue: queue)
    }

    private func setupConnection(_ connection: NWConnection, peer: PeerDevice) {
        let peerConnection = PeerConnection(connection: connection, peer: peer)
        connections[peer.id] = peerConnection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(state, peer: peer)
        }

        // Start receiving data
        receiveData(on: connection, peer: peer)
    }

    private func handleConnectionStateChange(_ state: NWConnection.State, peer: PeerDevice) {
        switch state {
        case .ready:
            updateState(.connected)
            delegate?.transport(self, didConnect: peer)
            print("✅ Connected to \(peer.name)")

        case .failed(let error):
            connections.removeValue(forKey: peer.id)
            delegate?.transport(self, didDisconnect: peer, error: error)
            print("❌ Connection to \(peer.name) failed: \(error)")

        case .cancelled:
            connections.removeValue(forKey: peer.id)
            print("🛑 Connection to \(peer.name) cancelled")

        default:
            break
        }
    }

    private func sendData(_ data: Data, on connection: NWConnection) {
        // Send length prefix (4 bytes) followed by data
        var lengthData = Data()
        var length = UInt32(data.count).bigEndian
        lengthData.append(Data(bytes: &length, count: 4))

        connection.send(content: lengthData + data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Send failed: \(error)")
            }
        })
    }

    private func receiveData(on connection: NWConnection, peer: PeerDevice) {
        // First receive 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Receive error: \(error)")
                return
            }

            if isComplete {
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                print("❌ Invalid length data")
                return
            }

            // Parse length
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Receive actual data
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, isComplete, error in
                if let error = error {
                    print("❌ Receive payload error: \(error)")
                    return
                }

                if let data = data {
                    self.delegate?.transport(self, didReceive: data, from: peer)
                }

                // Continue receiving
                if !isComplete {
                    self.receiveData(on: connection, peer: peer)
                }
            }
        }
    }

    private func findBrowseResult(for peer: PeerDevice) -> NWBrowser.Result? {
        return browser?.browseResults.first { result in
            if case .service(let name, _, _, _) = result.endpoint {
                // Use same deterministic ID generation
                let peerId = UUID(uuid: name.utf8.withContiguousStorageIfAvailable { bytes in
                    var hasher = (0..<16).map { _ in UInt8(0) }
                    for (index, byte) in bytes.prefix(16).enumerated() {
                        hasher[index] = byte
                    }
                    return uuid_t(
                        hasher[0], hasher[1], hasher[2], hasher[3],
                        hasher[4], hasher[5], hasher[6], hasher[7],
                        hasher[8], hasher[9], hasher[10], hasher[11],
                        hasher[12], hasher[13], hasher[14], hasher[15]
                    )
                } ?? uuid_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
                return peerId == peer.id
            }
            return false
        }
    }

    private func updateState(_ newState: TransportState) {
        guard state != newState else { return }
        state = newState
        delegate?.transport(self, didChangeState: newState)
    }
}

// MARK: - Helper Types

private struct PeerConnection {
    let connection: NWConnection
    let peer: PeerDevice
}

// MARK: - Errors

public enum TransportError: Error {
    case advertisingFailed(Error)
    case browserFailed(Error)
    case listenerFailed(Error)
    case peerNotFound
    case notConnected
}
