import SwiftUI
import PencilKit
import SpiderbrainKit

/// M1's whole job: draw on both surfaces and decide whether the custom renderer
/// holds up against PencilKit. Switch between them mid-sentence - the difference,
/// if there is one, shows up in the pen-to-ink gap, not in a screenshot.
struct ContentView: View {
    @State private var engine: Engine = .metal
    @State private var mode: DrawMode = .draw
    @State private var predictionEnabled = true
    @State private var stats = MetalInkView.HUDStats()
    @State private var clearToken = 0
    @State private var undoToken = 0

    // M2 prototype: Auto-detection and sidebar state
    @State private var queuedNodeIndices: [Int] = []
    @State private var shapesWithNodes: [(strokeIndex: Int, nodeIndices: [Int])] = []
    @State private var sidebarExpanded = false
    @State private var convertNodeToken = 0
    @State private var convertNodeIndex: Int? = nil
    @State private var absorbNodeToken = 0
    @State private var absorbNodeIndex: Int? = nil
    @State private var existingNodes: [Node] = []
    @State private var refreshTrigger = 0
    @State private var detectNodeId: UUID? = nil
    @State private var detectToken = 0
    @State private var deleteNodeId: UUID? = nil
    @State private var deleteToken = 0
    @State private var lasssoedNodeId: UUID? = nil
    @State private var lassoedStrokes: [Stroke] = []
    @State private var absorbToken = 0
    @State private var separateToken = 0
    @State private var selectedNodeId: UUID? = nil
    @State private var selectedConnectionId: UUID? = nil
    @State private var deleteConnectionToken = 0
    @State private var recognizeNodeId: UUID? = nil
    @State private var recognizeToken = 0
    @State private var showingFullText = false
    @State private var fullTextToShow: String = ""
    @State private var correctionNodeData: CorrectionNodeData?
    @State private var showingMLTraining = false
    @State private var showingNetworkTest = false

    // Sync state
    @StateObject private var syncCoordinator = SyncCoordinator()
    @State private var isSyncActive = false
    @State private var connectedPeers: [PeerDevice] = []

    struct CorrectionNodeData: Identifiable {
        let id: UUID
        let recognized: RecognizedText
        let strokes: [Stroke]
        let bounds: Rect
    }

    enum Engine: String, CaseIterable, Identifiable {
        case metal = "Spiderbrain"
        case pencilKit = "PencilKit"
        var id: String { rawValue }
    }

    enum DrawMode: String, CaseIterable, Identifiable {
        case draw = "Draw"
        case lasso = "Lasso"
        var id: String { rawValue }
    }

    var body: some View {
        // Debug logging - uncomment if needed
        // let _ = print("🟣 VIEW BODY: existingNodes has \(existingNodes.count) nodes, refreshTrigger: \(refreshTrigger)")
        // let _ = existingNodes.first.map { print("🟣 VIEW BODY: first node has \($0.strokes.count) strokes") }

        ZStack(alignment: .topLeading) {
            Group {
                switch engine {
                case .metal:
                    MetalInkCanvas(
                        mode: mode,
                        predictionEnabled: predictionEnabled,
                        clearToken: clearToken,
                        undoToken: undoToken,
                        convertNodeToken: convertNodeToken,
                        convertNodeIndex: convertNodeIndex,
                        absorbNodeToken: absorbNodeToken,
                        absorbNodeIndex: absorbNodeIndex,
                        detectNodeId: detectNodeId,
                        detectToken: detectToken,
                        deleteNodeId: deleteNodeId,
                        deleteToken: deleteToken,
                        absorbToken: absorbToken,
                        separateToken: separateToken,
                        lassoedNodeId: lasssoedNodeId,
                        lassoedStrokes: lassoedStrokes,
                        selectedConnectionId: selectedConnectionId,
                        deleteConnectionToken: deleteConnectionToken,
                        recognizeNodeId: recognizeNodeId,
                        recognizeToken: recognizeToken,
                        syncCoordinator: syncCoordinator,
                        onStats: { stats = $0 },
                        onNodesUpdate: { _ in
                            // Not used - onNodesChanged handles updates
                        },
                        onNodesChanged: { nodes in
                            // Debug logging - uncomment if needed
                            // print("🔴 onNodesChanged called with \(nodes.count) nodes")
                            // if let first = nodes.first {
                            //     print("🔴 First node has \(first.strokes.count) strokes")
                            // }

                            // Deep copy each node with explicit stroke array copy
                            let nodesCopy = nodes.map { node in
                                Node(
                                    id: node.id,
                                    strokes: node.strokes.map { $0 },  // Explicit stroke copy
                                    bounds: node.bounds,
                                    style: node.style,
                                    boundaryStroke: node.boundaryStroke,
                                    connections: node.connections,
                                    recognizedText: node.recognizedText  // Include recognized text
                                )
                            }

                            // Debug logging - uncomment if needed
                            // print("🔴 Copy made with \(nodesCopy.count) nodes")
                            // if let first = nodesCopy.first {
                            //     print("🔴 Copy first node has \(first.strokes.count) strokes")
                            // }

                            DispatchQueue.main.async {
                                // Debug logging - uncomment if needed
                                // print("🔴 [ASYNC] Updating existingNodes")
                                // print("🔴 [ASYNC] BEFORE: existingNodes first node has \(existingNodes.first?.strokes.count ?? -1) strokes")
                                // if let first = nodesCopy.first {
                                //     print("🔴 [ASYNC] nodesCopy first node has \(first.strokes.count) strokes")
                                //     print("🔴 [ASYNC] nodesCopy first node ID: \(first.id)")
                                //     print("🔴 [ASYNC] nodesCopy first node strokes: \(first.strokes.map { $0.id })")
                                // }

                                // CRITICAL: Clear first to break any SwiftUI references to old node data
                                existingNodes = []
                                existingNodes = nodesCopy
                                refreshTrigger += 1

                                // Debug logging - uncomment if needed
                                // print("🔴 [ASYNC] refreshTrigger now: \(refreshTrigger)")
                                // print("🔴 [ASYNC] AFTER: existingNodes first node has \(existingNodes.first?.strokes.count ?? -1) strokes")
                                // if let first = existingNodes.first {
                                //     print("🔴 [ASYNC] AFTER: existingNodes first node strokes: \(first.strokes.map { $0.id })")
                                // }
                            }
                        },
                        onClosedShapeDetected: { strokeIndex in
                            // Add to queue if not already there
                            if !queuedNodeIndices.contains(strokeIndex) {
                                queuedNodeIndices.append(strokeIndex)
                            }
                        },
                        onClosedShapeWithNodes: { strokeIndex, nodeIndices in
                            // Add to shapes with nodes queue
                            shapesWithNodes.append((strokeIndex: strokeIndex, nodeIndices: nodeIndices))
                        },
                        onNodeLassoed: { nodeId, strokes in
                            lasssoedNodeId = nodeId
                            lassoedStrokes = strokes
                        },
                        onClearLassoState: {
                            lasssoedNodeId = nil
                            lassoedStrokes = []
                        },
                        onNodeSelected: { nodeId in
                            selectedNodeId = nodeId
                        },
                        onConnectionSelected: { connectionId in
                            selectedConnectionId = connectionId
                        }
                    )
                    .id("metal")
                case .pencilKit:
                    PencilKitCanvas(
                        clearToken: clearToken,
                        syncManager: syncCoordinator.canvasSyncManager,
                        receivedDrawing: syncCoordinator.receivedDrawing,
                        receivedDrawingToken: syncCoordinator.receivedDrawingToken
                    )
                        .id("pencilkit")
                }
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                controls
                Spacer()
            }

            // M2 prototype: Slide-out sidebar from left edge
            HStack(spacing: 0) {
                sidebar
                Spacer()
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Picker("Engine", selection: $engine) {
                    ForEach(Engine.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                if engine == .metal {
                    Picker("Mode", selection: $mode) {
                        ForEach(DrawMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    Toggle("Prediction", isOn: $predictionEnabled)
                        .toggleStyle(.switch)
                        .fixedSize()
                }

                Spacer()

                Button("Undo") { undoToken += 1 }
                    .disabled(engine != .metal)
                Button("Clear") { clearToken += 1 }
            }

            if engine == .metal {
                HStack(spacing: 18) {
                    stat("fps", String(format: "%.0f", stats.displayFPS))
                    stat("cpu", String(format: "%.2f ms", stats.cpuFrameMilliseconds))
                    stat("strokes", "\(stats.strokeCount)")
                    stat("samples", "\(stats.liveSamples)")
                    stat("predicted", "\(stats.predictedSamples)")
                    stat("corrections", "\(stats.estimateCorrections)")
                    stat("verts", "\(stats.liveVertices + stats.committedVertices)")
                    Spacer()
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            } else {
                Text("Reference implementation. Draw the same words on both and compare the gap between nib and ink.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private var sidebar: some View {
        HStack(spacing: 0) {
            // Expanded sidebar content
            if sidebarExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    // Sidebar header
                    HStack {
                        Text("Tools")
                            .font(.headline)
                            .fontWeight(.semibold)

                        Spacer()
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Node queue section
                            if !queuedNodeIndices.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("Detected Shapes")
                                            .font(.subheadline)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text("\(queuedNodeIndices.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.2))
                                            .clipShape(Capsule())
                                    }

                                    // List of queued nodes
                                    ForEach(Array(queuedNodeIndices.enumerated()), id: \.offset) { index, strokeIndex in
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Shape \(index + 1)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Text("Stroke #\(strokeIndex)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Button("Create") {
                                                convertNodeIndex = strokeIndex
                                                convertNodeToken += 1
                                                queuedNodeIndices.removeAll { $0 == strokeIndex }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)

                                            Button(action: {
                                                queuedNodeIndices.removeAll { $0 == strokeIndex }
                                            }) {
                                                Image(systemName: "xmark")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(Color.secondary.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }

                                    // Batch actions
                                    if queuedNodeIndices.count > 1 {
                                        HStack(spacing: 12) {
                                            Button("Create All") {
                                                for strokeIndex in queuedNodeIndices.reversed() {
                                                    convertNodeIndex = strokeIndex
                                                    convertNodeToken += 1
                                                }
                                                queuedNodeIndices.removeAll()
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)

                                            Button("Dismiss All") {
                                                queuedNodeIndices.removeAll()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                                .padding(16)

                                Divider()
                            }

                            // Shapes with nodes inside - absorb option
                            if !shapesWithNodes.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("Shapes with Nodes")
                                            .font(.subheadline)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text("\(shapesWithNodes.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.2))
                                            .clipShape(Capsule())
                                    }

                                    // List of shapes with nodes
                                    ForEach(Array(shapesWithNodes.enumerated()), id: \.offset) { index, shape in
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Shape \(index + 1)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                Text("\(shape.nodeIndices.count) node\(shape.nodeIndices.count == 1 ? "" : "s") inside")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Button("Absorb") {
                                                absorbNodeIndex = shape.strokeIndex
                                                absorbNodeToken += 1
                                                shapesWithNodes.remove(at: index)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)

                                            Button("Create Empty") {
                                                convertNodeIndex = shape.strokeIndex
                                                convertNodeToken += 1
                                                shapesWithNodes.remove(at: index)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button(action: {
                                                shapesWithNodes.remove(at: index)
                                            }) {
                                                Image(systemName: "xmark")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(Color.orange.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .padding(16)

                                Divider()
                            }

                            // Selected connection - delete option
                            if selectedConnectionId != nil {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Connection Selected")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    HStack(spacing: 12) {
                                        Button("Delete") {
                                            deleteConnectionToken += 1
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)
                                        .controlSize(.small)

                                        Button("Cancel") {
                                            selectedConnectionId = nil
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(16)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 16)
                                .padding(.top, 8)

                                Divider()
                            }

                            // Lassoed node - absorb/separate options
                            if lasssoedNodeId != nil, !lassoedStrokes.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Node Selected")
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    Text("\(lassoedStrokes.count) stroke\(lassoedStrokes.count == 1 ? "" : "s") selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 12) {
                                        Button("Absorb") {
                                            absorbToken += 1
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)

                                        Button("Separate") {
                                            separateToken += 1
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("Cancel") {
                                            lasssoedNodeId = nil
                                            lassoedStrokes = []
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(16)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 16)
                                .padding(.top, 8)

                                Divider()
                            }

                            // Existing nodes list
                            if !existingNodes.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("Nodes")
                                            .font(.subheadline)
                                            .fontWeight(.medium)

                                        Spacer()

                                        Text("\(existingNodes.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.2))
                                            .clipShape(Capsule())
                                    }

                                    // List of existing nodes
                                    // Combine refreshTrigger with index to force refresh when contents change
                                    ForEach(Array(existingNodes.enumerated()), id: \.offset) { index, node in
                                        // Debug logging - uncomment if needed
                                        // let _ = print("🔵 Rendering node \(index): \(node.strokes.count) strokes, refreshTrigger: \(refreshTrigger)")

                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Node \(index + 1)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)

                                                Text("\(node.strokes.count) stroke\(node.strokes.count == 1 ? "" : "s")")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .id("\(node.id)-\(node.strokes.count)-\(refreshTrigger)")

                                                // Show recognized text if available
                                                if let recognized = node.recognizedText {
                                                    Button(action: {
                                                        correctionNodeData = CorrectionNodeData(
                                                            id: node.id,
                                                            recognized: recognized,
                                                            strokes: node.strokes,
                                                            bounds: node.bounds
                                                        )
                                                    }) {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: sourceIcon(for: recognized.source))
                                                                .font(.caption2)
                                                                .foregroundStyle(.green)

                                                            Text("\"\(recognized.text)\"")
                                                                .font(.caption)
                                                                .foregroundStyle(.primary)
                                                                .lineLimit(1)

                                                            Text("\(Int(recognized.confidence * 100))%")
                                                                .font(.caption2)
                                                                .foregroundStyle(.secondary)
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.top, 2)
                                                }
                                            }

                                            Spacer()

                                            VStack(spacing: 4) {
                                                // Text recognition button
                                                Button(action: {
                                                    recognizeNodeId = node.id
                                                    recognizeToken += 1
                                                }) {
                                                    Image(systemName: "text.viewfinder")
                                                        .font(.caption)
                                                        .foregroundStyle(.green)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)

                                                // Detect button (absorb strokes)
                                                Button(action: {
                                                    detectNodeId = node.id
                                                    detectToken += 1
                                                }) {
                                                    Image(systemName: "eye.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.blue)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)

                                                // Delete button
                                                Button(action: {
                                                    deleteNodeId = node.id
                                                    deleteToken += 1
                                                }) {
                                                    Image(systemName: "trash")
                                                        .font(.caption2)
                                                        .foregroundStyle(.red)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(node.id == selectedNodeId ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .padding(16)
                                .id(refreshTrigger)  // Force refresh when nodes change

                                Divider()
                            }

                            // Tools Section
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Tools")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                // ML Training
                                Button(action: {
                                    showingMLTraining = true
                                }) {
                                    HStack {
                                        Image(systemName: "brain.head.profile")
                                            .font(.caption)
                                            .foregroundStyle(.blue)

                                        Text("Train Custom Model")
                                            .font(.caption)

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)

                                // Network Test
                                Button(action: {
                                    showingNetworkTest = true
                                }) {
                                    HStack {
                                        Image(systemName: "network")
                                            .font(.caption)
                                            .foregroundStyle(.green)

                                        Text("Network Test")
                                            .font(.caption)

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)

                                // Canvas Sync
                                Button(action: {
                                    toggleSync()
                                }) {
                                    HStack {
                                        Image(systemName: isSyncActive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                            .font(.caption)
                                            .foregroundStyle(isSyncActive ? .green : .gray)

                                        Text(isSyncActive ? "Sync Active (\(syncCoordinator.connectedPeers.count))" : "Start Sync")
                                            .font(.caption)

                                        Spacer()

                                        if isSyncActive {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 8, height: 8)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(width: 280)
                .background(.regularMaterial)
                .transition(.move(edge: .leading))
            }

            // Hamburger menu button (always visible)
            VStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sidebarExpanded.toggle()
                    }
                }) {
                    VStack(spacing: 0) {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .padding(12)

                        // Badge for queued items or existing nodes
                        let totalCount = queuedNodeIndices.count + existingNodes.count
                        if totalCount > 0 {
                            Text("\(totalCount)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.blue)
                                .clipShape(Circle())
                                .offset(y: -8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.1), radius: 4)

                Spacer()
            }
            .padding(.leading, sidebarExpanded ? 0 : 8)
            .padding(.top, 120)
        }
        .alert("Recognized Text", isPresented: $showingFullText) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(fullTextToShow)
        }
        .sheet(item: $correctionNodeData) { data in
            TextCorrectionSheet(
                recognizedText: data.recognized,
                nodeId: data.id,
                nodeStrokes: data.strokes,
                nodeBounds: data.bounds,
                onCorrect: { correctedText in
                    handleCorrection(
                        nodeId: data.id,
                        recognized: data.recognized,
                        correctedText: correctedText,
                        strokes: data.strokes,
                        bounds: data.bounds
                    )
                }
            )
        }
        .sheet(isPresented: $showingMLTraining) {
            MLTrainingView()
        }
        .sheet(isPresented: $showingNetworkTest) {
            NetworkTestView()
        }
    }

    // MARK: - Helper Functions

    /// Get icon for recognition source
    private func sourceIcon(for source: RecognizedText.RecognitionSourceData) -> String {
        switch source {
        case .vision:
            return "eye.fill"
        case .customModel:
            return "brain.head.profile"
        case .correctionHistory:
            return "checkmark.circle.fill"
        }
    }

    /// Handle a correction from the user
    private func handleCorrection(
        nodeId: UUID,
        recognized: RecognizedText,
        correctedText: String,
        strokes: [Stroke],
        bounds: Rect
    ) {
        // Render strokes to image for training data
        let strokeImage = StrokeImageRenderer.render(
            strokes: strokes,
            bounds: bounds
        )

        // Create correction sample
        let sample = CorrectionSample(
            nodeId: nodeId,
            visionResult: recognized.text,
            visionConfidence: recognized.confidence,
            userCorrection: correctedText,
            strokeImage: strokeImage,
            strokeCount: strokes.count,
            boundsWidth: bounds.width,
            boundsHeight: bounds.height
        )

        // Store correction
        let storage = CorrectionStorageManager()
        storage.addCorrection(sample)

        // Update the node's recognized text to show the correction
        updateNodeWithCorrection(nodeId: nodeId, correctedText: correctedText)

        print("✅ Saved correction: \"\(recognized.text)\" → \"\(correctedText)\"")
    }

    /// Update a node's recognized text with the user's correction
    private func updateNodeWithCorrection(nodeId: UUID, correctedText: String) {
        guard let index = existingNodes.firstIndex(where: { $0.id == nodeId }) else { return }

        // Create new recognized text with correction source
        let correctedRecognition = RecognizedText(
            text: correctedText,
            confidence: 1.0, // User correction is 100% confident
            source: .correctionHistory(matchConfidence: 1.0)
        )

        // Update the node
        existingNodes[index].recognizedText = correctedRecognition
        refreshTrigger += 1
    }

    // MARK: - Canvas Sync

    private func toggleSync() {
        if isSyncActive {
            // Stop sync
            syncCoordinator.stopSync()
            isSyncActive = false
        } else {
            // Start sync
            do {
                let deviceName: String

                #if targetEnvironment(macCatalyst)
                // Running on Mac via Catalyst
                deviceName = "\(Host.current().localizedName ?? "Mac")-Mac"
                print("🖥️ Running as Mac Catalyst, using device name: \(deviceName)")
                #elseif os(iOS)
                // Native iOS (iPhone/iPad)
                // Check if running on Mac (even if compiled for iOS)
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    // Get Mac name - use environment or fallback
                    let machineName = ProcessInfo.processInfo.hostName
                    deviceName = "\(machineName)-Mac"
                    print("🖥️ Running iOS app on Mac, using device name: \(deviceName)")
                } else {
                    deviceName = "\(UIDevice.current.name)-iOS"
                    print("📱 Running on native iOS, using device name: \(deviceName)")
                }
                #elseif os(macOS)
                // Native macOS
                deviceName = "\(Host.current().localizedName ?? "Mac")-Mac"
                print("🖥️ Running on native macOS, using device name: \(deviceName)")
                #endif

                try syncCoordinator.startSync(deviceName: deviceName)
                isSyncActive = true
                print("✅ Canvas sync started")
            } catch {
                print("❌ Failed to start sync: \(error)")
            }
        }
    }
}

// MARK: - Sync Coordinator

class SyncCoordinator: ObservableObject {
    @Published var receivedDrawing: PKDrawing? = nil
    @Published var receivedDrawingToken = 0
    @Published var connectedPeers: [PeerDevice] = []
    @Published var receivedStrokes: [Stroke] = []
    @Published var receivedStrokesToken = 0

    var canvasSyncManager: CanvasSyncManager?
    var metalSyncManager: MetalStrokeSyncManager?
    weak var metalView: MetalInkView?

    func startSync(deviceName: String) throws {
        let transport = BonjourTransport()

        // Start PencilKit sync (for reference)
        let canvasManager = CanvasSyncManager(transport: transport)
        canvasManager.delegate = self
        self.canvasSyncManager = canvasManager

        // Start Metal sync
        let metalManager = MetalStrokeSyncManager(transport: transport)
        metalManager.delegate = self
        self.metalSyncManager = metalManager

        try metalManager.startSync(deviceName: deviceName)
    }

    func stopSync() {
        canvasSyncManager?.stopSync()
        canvasSyncManager = nil
        metalSyncManager?.stopSync()
        metalSyncManager = nil
        connectedPeers = []
    }

    func sendStroke(_ stroke: Stroke) {
        metalSyncManager?.sendStroke(stroke)
    }

    func deleteStroke(id: UUID) {
        metalSyncManager?.deleteStroke(id: id)
    }

    func sendNode(_ node: Node) {
        metalSyncManager?.sendNode(node)
    }

    func sendNodeWithStrokeDeletions(_ node: Node, deletedStrokeIds: [UUID]) {
        metalSyncManager?.sendNodeWithStrokeDeletions(node, deletedStrokeIds: deletedStrokeIds)
    }

    func updateNode(_ node: Node) {
        metalSyncManager?.updateNode(node)
    }

    func deleteNode(id: UUID) {
        metalSyncManager?.deleteNode(id: id)
    }

    func sendConnection(_ connection: Connection) {
        metalSyncManager?.sendConnection(connection)
    }

    func deleteConnection(id: UUID) {
        metalSyncManager?.deleteConnection(id: id)
    }
}

extension SyncCoordinator: CanvasSyncDelegate {
    func canvasSync(_ manager: CanvasSyncManager, didDiscoverPeer peer: PeerDevice) {
        print("👋 Discovered peer: \(peer.name)")
    }

    func canvasSync(_ manager: CanvasSyncManager, didLosePeer peer: PeerDevice) {
        print("👋 Lost peer: \(peer.name)")
    }

    func canvasSync(_ manager: CanvasSyncManager, didConnectToPeer peer: PeerDevice) {
        DispatchQueue.main.async {
            self.connectedPeers.append(peer)
        }
        print("✅ Connected to peer: \(peer.name)")
    }

    func canvasSync(_ manager: CanvasSyncManager, didDisconnectFromPeer peer: PeerDevice) {
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0.id == peer.id }
        }
        print("🔌 Disconnected from peer: \(peer.name)")
    }

    func canvasSync(_ manager: CanvasSyncManager, didReceiveDrawing drawing: PKDrawing, from peer: PeerDevice) {
        print("📥 Received drawing from \(peer.name)")
        DispatchQueue.main.async {
            self.receivedDrawing = drawing
            self.receivedDrawingToken += 1
        }
    }

    func canvasSync(_ manager: CanvasSyncManager, didEncounterError error: Error) {
        print("❌ Sync error: \(error)")
    }
}

extension SyncCoordinator: MetalStrokeSyncDelegate {
    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDiscoverPeer peer: PeerDevice) {
        print("👋 Metal: Discovered peer: \(peer.name)")
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didLosePeer peer: PeerDevice) {
        print("👋 Metal: Lost peer: \(peer.name)")
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didConnectToPeer peer: PeerDevice) {
        DispatchQueue.main.async {
            if !self.connectedPeers.contains(where: { $0.id == peer.id }) {
                self.connectedPeers.append(peer)
            }
        }
        print("✅ Metal: Connected to peer: \(peer.name)")
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDisconnectFromPeer peer: PeerDevice) {
        DispatchQueue.main.async {
            self.connectedPeers.removeAll { $0.id == peer.id }
        }
        print("🔌 Metal: Disconnected from peer: \(peer.name)")
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveStroke stroke: Stroke, from peer: PeerDevice) {
        print("📥 Metal: Received stroke from \(peer.name)")
        DispatchQueue.main.async {
            // Add the received stroke to the Metal view
            self.metalView?.addReceivedStroke(stroke)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteStroke id: UUID, from peer: PeerDevice) {
        print("🗑 Metal: Delete stroke \(id) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.deleteReceivedStroke(id: id)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveNode node: Node, from peer: PeerDevice) {
        print("📥 Metal: Received node \(node.id) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.addReceivedNode(node)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveNodeWithStrokeDeletions node: Node, deletedStrokeIds: [UUID], from peer: PeerDevice) {
        print("📥 Metal: Received node \(node.id) with \(deletedStrokeIds.count) stroke deletions from \(peer.name)")
        DispatchQueue.main.async {
            // Delete the strokes first
            for strokeId in deletedStrokeIds {
                self.metalView?.deleteReceivedStroke(id: strokeId)
            }
            // Then add the node
            self.metalView?.addReceivedNode(node)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didUpdateNode node: Node, from peer: PeerDevice) {
        print("📥 Metal: Received node update \(node.id) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.updateReceivedNode(node)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteNode id: UUID, from peer: PeerDevice) {
        print("🗑 Metal: Received node deletion \(id) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.deleteReceivedNode(id: id)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveConnection connection: Connection, from peer: PeerDevice) {
        print("📥 Metal: Received connection \(connection.id) from \(connection.from) to \(connection.to) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.addReceivedConnection(connection)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didDeleteConnection id: UUID, from peer: PeerDevice) {
        print("🗑 Metal: Received connection deletion \(id) from \(peer.name)")
        DispatchQueue.main.async {
            self.metalView?.deleteReceivedConnection(id: id)
        }
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didReceiveFullSync strokes: [Stroke], from peer: PeerDevice) {
        print("📥 Metal: Received full sync with \(strokes.count) strokes from \(peer.name)")
    }

    func metalStrokeSync(_ manager: MetalStrokeSyncManager, didEncounterError error: Error) {
        print("❌ Metal sync error: \(error)")
    }
}

// MARK: - Bridges

private struct MetalInkCanvas: UIViewRepresentable {
    var mode: ContentView.DrawMode
    var predictionEnabled: Bool
    var clearToken: Int
    var undoToken: Int
    var convertNodeToken: Int
    var convertNodeIndex: Int?
    var absorbNodeToken: Int
    var absorbNodeIndex: Int?
    var detectNodeId: UUID?
    var detectToken: Int
    var deleteNodeId: UUID?
    var deleteToken: Int
    var absorbToken: Int
    var separateToken: Int
    var lassoedNodeId: UUID?
    var lassoedStrokes: [Stroke]
    var selectedConnectionId: UUID?
    var deleteConnectionToken: Int
    var recognizeNodeId: UUID?
    var recognizeToken: Int
    var syncCoordinator: SyncCoordinator
    var onStats: (MetalInkView.HUDStats) -> Void
    var onNodesUpdate: ([Node]) -> Void
    var onNodesChanged: (([Node]) -> Void)?
    var onClosedShapeDetected: ((Int) -> Void)?
    var onClosedShapeWithNodes: ((Int, [Int]) -> Void)?
    var onNodeLassoed: ((UUID, [Stroke]) -> Void)?
    var onClearLassoState: (() -> Void)?
    var onNodeSelected: ((UUID?) -> Void)?
    var onConnectionSelected: ((UUID?) -> Void)?

    func makeUIView(context: Context) -> MetalInkView {
        guard let view = MetalInkView(frame: .zero) else {
            fatalError("Metal is unavailable. Run on a device, not the simulator.")
        }
        view.onStatsUpdate = onStats
        view.onClosedShapeDetected = onClosedShapeDetected
        view.onClosedShapeWithNodes = onClosedShapeWithNodes
        view.onNodeLassoed = onNodeLassoed
        view.onNodesChanged = onNodesChanged
        view.onNodeSelected = onNodeSelected
        view.onConnectionSelected = onConnectionSelected

        // Set up sync callbacks
        view.onStrokeCommitted = { stroke in
            syncCoordinator.sendStroke(stroke)
        }

        view.onStrokeDeleted = { strokeId in
            syncCoordinator.deleteStroke(id: strokeId)
        }

        view.onNodeCreated = { node in
            syncCoordinator.sendNode(node)
        }

        view.onNodeCreatedWithStrokeDeletions = { node, deletedStrokeIds in
            syncCoordinator.sendNodeWithStrokeDeletions(node, deletedStrokeIds: deletedStrokeIds)
        }

        view.onNodeUpdated = { node in
            syncCoordinator.updateNode(node)
        }

        view.onNodeDeleted = { id in
            syncCoordinator.deleteNode(id: id)
        }

        view.onConnectionCreated = { connection in
            syncCoordinator.sendConnection(connection)
        }

        view.onConnectionDeleted = { id in
            syncCoordinator.deleteConnection(id: id)
        }

        // Store reference for receiving strokes and nodes
        syncCoordinator.metalView = view

        context.coordinator.lastClear = clearToken
        context.coordinator.lastUndo = undoToken
        context.coordinator.lastConvertNode = convertNodeToken
        context.coordinator.lastDetect = detectToken
        context.coordinator.lastDelete = deleteToken
        context.coordinator.lastAbsorb = absorbToken
        context.coordinator.lastSeparate = separateToken
        context.coordinator.lastRecognize = recognizeToken
        return view
    }

    func updateUIView(_ view: MetalInkView, context: Context) {
        // Update mode
        view.drawMode = mode == .draw ? .draw : .lasso

        view.predictionEnabled = predictionEnabled
        view.onClosedShapeDetected = onClosedShapeDetected
        view.onNodeLassoed = onNodeLassoed
        view.onNodeSelected = onNodeSelected

        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            view.clear()
        }
        if context.coordinator.lastUndo != undoToken {
            context.coordinator.lastUndo = undoToken
            view.undoLastStroke()
        }
        if context.coordinator.lastConvertNode != convertNodeToken,
           let strokeIndex = convertNodeIndex {
            context.coordinator.lastConvertNode = convertNodeToken
            view.convertStrokeToNode(at: strokeIndex)
        }

        // Handle detect strokes (one-time absorb)
        if context.coordinator.lastDetect != detectToken,
           let nodeId = detectNodeId {
            context.coordinator.lastDetect = detectToken
            view.detectStrokesInNode(nodeId: nodeId)
        }

        // Handle node deletion
        if context.coordinator.lastDelete != deleteToken,
           let nodeId = deleteNodeId {
            context.coordinator.lastDelete = deleteToken
            view.deleteNode(id: nodeId)
        }

        // Handle connection deletion
        if context.coordinator.lastDeleteConnection != deleteConnectionToken,
           let connectionId = selectedConnectionId {
            context.coordinator.lastDeleteConnection = deleteConnectionToken
            view.removeConnection(id: connectionId)
            context.coordinator.shouldClearConnectionSelection = true
        }

        // Handle absorb nodes (from draw mode)
        if context.coordinator.lastAbsorbNode != absorbNodeToken,
           let strokeIndex = absorbNodeIndex {
            context.coordinator.lastAbsorbNode = absorbNodeToken
            view.convertStrokeToNodeWithAbsorb(at: strokeIndex)
        }

        // Handle absorb (from lasso mode)
        if context.coordinator.lastAbsorb != absorbToken,
           let nodeId = lassoedNodeId {
            context.coordinator.lastAbsorb = absorbToken
            view.absorbIntoNode(nodeId: nodeId, strokes: lassoedStrokes)
            // Trigger callback to clear lasso state
            context.coordinator.shouldClearLassoState = true
        }

        // Handle separate
        if context.coordinator.lastSeparate != separateToken {
            context.coordinator.lastSeparate = separateToken
            view.separateIntoNewNode(strokes: lassoedStrokes)
            // Trigger callback to clear lasso state
            context.coordinator.shouldClearLassoState = true
        }

        // Handle text recognition
        if context.coordinator.lastRecognize != recognizeToken,
           let nodeId = recognizeNodeId {
            context.coordinator.lastRecognize = recognizeToken
            Task {
                await view.recognizeTextInNode(nodeId: nodeId)
            }
        }

        // Clear lasso state if requested
        if context.coordinator.shouldClearLassoState {
            context.coordinator.shouldClearLassoState = false
            DispatchQueue.main.async {
                onClearLassoState?()
            }
        }

        // Clear connection selection if requested
        if context.coordinator.shouldClearConnectionSelection {
            context.coordinator.shouldClearConnectionSelection = false
            DispatchQueue.main.async {
                onConnectionSelected?(nil)
            }
        }

        // Update nodes list
        onNodesUpdate(view.allNodes)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastClear = 0
        var lastUndo = 0
        var lastConvertNode = 0
        var lastAbsorbNode = 0
        var lastDetect = 0
        var lastDelete = 0
        var lastAbsorb = 0
        var lastSeparate = 0
        var lastDeleteConnection = 0
        var lastRecognize = 0
        var shouldClearLassoState = false
        var shouldClearConnectionSelection = false
    }
}

private struct PencilKitCanvas: UIViewControllerRepresentable {
    var clearToken: Int
    var syncManager: CanvasSyncManager?
    var receivedDrawing: PKDrawing?
    var receivedDrawingToken: Int

    func makeUIViewController(context: Context) -> PKCanvasViewController {
        let vc = PKCanvasViewController(clearToken: clearToken)
        vc.syncManager = syncManager
        vc.canvasView.delegate = context.coordinator
        context.coordinator.canvasViewController = vc
        return vc
    }

    func updateUIViewController(_ vc: PKCanvasViewController, context: Context) {
        // Update sync manager
        vc.syncManager = syncManager

        // Handle received drawing
        if context.coordinator.lastReceivedToken != receivedDrawingToken,
           let drawing = receivedDrawing {
            context.coordinator.lastReceivedToken = receivedDrawingToken
            vc.applyReceivedDrawing(drawing)
        }

        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            vc.canvasView.drawing = PKDrawing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var lastClear = 0
        var lastReceivedToken = 0
        weak var canvasViewController: PKCanvasViewController?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Send drawing to connected peers
            canvasViewController?.syncDrawing()
        }
    }
}

private class PKCanvasViewController: UIViewController {
    let canvasView = PKCanvasView()
    var syncManager: CanvasSyncManager?

    init(clearToken: Int) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvasView.backgroundColor = UIColor(white: 0.99, alpha: 1)
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func syncDrawing() {
        guard let syncManager = syncManager else { return }
        syncManager.syncDrawing(canvasView.drawing)
    }

    func applyReceivedDrawing(_ drawing: PKDrawing) {
        canvasView.drawing = drawing
    }
}
