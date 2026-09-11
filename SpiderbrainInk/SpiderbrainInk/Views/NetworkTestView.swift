import SwiftUI
import SpiderbrainKit

struct NetworkTestView: View {
    @StateObject private var viewModel = NetworkTestViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status
                VStack(spacing: 8) {
                    Text("Connection Status")
                        .font(.headline)

                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 12, height: 12)
                        Text(viewModel.statusText)
                            .font(.subheadline)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)

                // Controls
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        Button(viewModel.isAdvertising ? "Stop Advertising" : "Start Advertising") {
                            viewModel.toggleAdvertising()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(viewModel.isAdvertising ? .red : .blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)

                        Button(viewModel.isBrowsing ? "Stop Browsing" : "Start Browsing") {
                            viewModel.toggleBrowsing()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(viewModel.isBrowsing ? .red : .green)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Available Peers
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Devices (\(viewModel.availablePeers.count))")
                        .font(.headline)
                        .padding(.horizontal)

                    List {
                        if viewModel.availablePeers.isEmpty {
                            Text("No devices found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(viewModel.availablePeers, id: \.id) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(peer.platform.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Connect") {
                                    viewModel.connect(to: peer)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(height: 200)
                }

                Divider()

                // Connected Peers
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connected Devices (\(viewModel.connectedPeers.count))")
                        .font(.headline)
                        .padding(.horizontal)

                    List {
                        if viewModel.connectedPeers.isEmpty {
                            Text("Not connected to any devices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(viewModel.connectedPeers, id: \.id) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(peer.platform.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Send Test") {
                                    viewModel.sendTestMessage(to: peer)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.green)

                                Button("Disconnect") {
                                    viewModel.disconnect(from: peer)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.red)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(height: 200)
                }

                Divider()

                // Messages Log
                VStack(alignment: .leading, spacing: 12) {
                    Text("Messages")
                        .font(.headline)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.messages.suffix(10), id: \.self) { message in
                                Text(message)
                                    .font(.caption)
                                    .padding(.vertical, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(8)
                }
                .padding(.horizontal)

                Spacer()
                }
                .padding()
            }
            .navigationTitle("Network Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusColor: Color {
        switch viewModel.transportState {
        case .disconnected:
            return .gray
        case .advertising, .browsing:
            return .yellow
        case .connecting:
            return .orange
        case .connected:
            return .green
        }
    }
}

class NetworkTestViewModel: ObservableObject {
    @Published var availablePeers: [PeerDevice] = []
    @Published var connectedPeers: [PeerDevice] = []
    @Published var messages: [String] = []
    @Published var transportState: TransportState = .disconnected
    @Published var isAdvertising = false
    @Published var isBrowsing = false

    private var transport: BonjourTransport?

    var statusText: String {
        switch transportState {
        case .disconnected:
            return "Disconnected"
        case .advertising:
            return "Advertising"
        case .browsing:
            return "Browsing"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        }
    }

    init() {
        setupTransport()
    }

    private func setupTransport() {
        let transport = BonjourTransport()
        transport.delegate = self
        self.transport = transport
        addMessage("✅ Transport initialized")
    }

    func toggleAdvertising() {
        guard let transport = transport else { return }

        if isAdvertising {
            transport.stopAdvertising()
            isAdvertising = false
            addMessage("🛑 Stopped advertising")
        } else {
            do {
                #if os(iOS)
                let baseName = UIDevice.current.name
                let deviceName = "\(baseName)-iOS"
                #elseif os(macOS)
                let baseName = Host.current().localizedName ?? "Mac"
                let deviceName = "\(baseName)-Mac"
                #endif

                try transport.startAdvertising(deviceName: deviceName)
                isAdvertising = true
                addMessage("📢 Started advertising as \"\(deviceName)\"")
            } catch {
                addMessage("❌ Failed to start advertising: \(error)")
            }
        }
    }

    func toggleBrowsing() {
        guard let transport = transport else { return }

        if isBrowsing {
            transport.stopBrowsing()
            isBrowsing = false
            addMessage("🛑 Stopped browsing")
        } else {
            do {
                try transport.startBrowsing()
                isBrowsing = true
                addMessage("🔍 Started browsing for peers")
            } catch {
                addMessage("❌ Failed to start browsing: \(error)")
            }
        }
    }

    func connect(to peer: PeerDevice) {
        guard let transport = transport else { return }

        do {
            try transport.connect(to: peer)
            addMessage("🔌 Connecting to \(peer.name)...")
        } catch {
            addMessage("❌ Failed to connect to \(peer.name): \(error)")
        }
    }

    func disconnect(from peer: PeerDevice) {
        guard let transport = transport else { return }
        transport.disconnect(from: peer)
        addMessage("🔌 Disconnected from \(peer.name)")
    }

    func sendTestMessage(to peer: PeerDevice) {
        guard let transport = transport else { return }

        let message = "Hello from \(transportState)! Time: \(Date())"
        guard let data = message.data(using: .utf8) else { return }

        do {
            try transport.send(data: data, to: peer)
            addMessage("📤 Sent: \(message)")
        } catch {
            addMessage("❌ Failed to send: \(error)")
        }
    }

    private func addMessage(_ message: String) {
        DispatchQueue.main.async {
            self.messages.append(message)
            print(message)
        }
    }
}

extension NetworkTestViewModel: TransportDelegate {
    func transport(_ transport: TransportProtocol, didDiscover peer: PeerDevice) {
        DispatchQueue.main.async {
            print("🔍 DEBUG: didDiscover called for peer: \(peer.name), ID: \(peer.id)")
            print("🔍 DEBUG: Current availablePeers count: \(self.availablePeers.count)")
            print("🔍 DEBUG: availablePeers: \(self.availablePeers.map { $0.name })")

            if !self.availablePeers.contains(where: { $0.id == peer.id }) {
                print("🔍 DEBUG: Adding peer to availablePeers")
                // Create new array instance to trigger SwiftUI update
                var newPeers = self.availablePeers
                newPeers.append(peer)
                self.availablePeers = newPeers
                print("🔍 DEBUG: New availablePeers count: \(self.availablePeers.count)")
                self.addMessage("👋 Discovered: \(peer.name) (\(peer.platform))")
            } else {
                print("🔍 DEBUG: Peer already in availablePeers, skipping")
            }
        }
    }

    func transport(_ transport: TransportProtocol, didLose peer: PeerDevice) {
        DispatchQueue.main.async {
            self.availablePeers.removeAll { $0.id == peer.id }
            self.addMessage("👋 Lost: \(peer.name)")
        }
    }

    func transport(_ transport: TransportProtocol, didChangeState state: TransportState) {
        DispatchQueue.main.async {
            self.transportState = state
            self.addMessage("🔄 State changed to: \(state)")
        }
    }

    func transport(_ transport: TransportProtocol, didConnect peer: PeerDevice) {
        DispatchQueue.main.async {
            if !self.connectedPeers.contains(where: { $0.id == peer.id }) {
                self.connectedPeers.append(peer)
            }
            self.availablePeers.removeAll { $0.id == peer.id }
            self.addMessage("✅ Connected to: \(peer.name)")
        }
    }

    func transport(_ transport: TransportProtocol, didDisconnect peer: PeerDevice, error: Error?) {
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0.id == peer.id }
            if let error = error {
                self.addMessage("❌ Disconnected from \(peer.name): \(error)")
            } else {
                self.addMessage("🔌 Disconnected from: \(peer.name)")
            }
        }
    }

    func transport(_ transport: TransportProtocol, didReceive data: Data, from peer: PeerDevice) {
        if let message = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async {
                self.addMessage("📥 Received from \(peer.name): \(message)")
            }
        }
    }

    func transport(_ transport: TransportProtocol, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.addMessage("❌ Error: \(error)")
        }
    }
}
