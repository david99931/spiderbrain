#if os(iOS)
import UIKit
import QuartzCore

/// Helper to identify strokes by their geometry for comparison.
/// Used when matching strokes from different sources (nodes vs canvas).
private struct StrokeIdentifier: Hashable {
    let pointCount: Int
    let firstPosition: Vec2?
    let lastPosition: Vec2?

    init(stroke: Stroke) {
        self.pointCount = stroke.points.count
        self.firstPosition = stroke.points.first?.position
        self.lastPosition = stroke.points.last?.position
    }
}

/// The M1 drawing surface: capture, tessellate, render.
///
/// Rendering is driven by `CADisplayLink`, never by touch callbacks. Touches only
/// append samples; the display link decides when to draw. Drawing from
/// `touchesMoved` couples frame rate to input rate and produces uneven pacing.
public final class MetalInkView: UIView {

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let renderer: InkRenderer
    private let collector = StrokeInputCollector()
    private var displayLink: CADisplayLink?

    // MARK: - Data Storage
    // Note: These are the actual data stores. Managers were an over-optimization
    // that broke mutability. Keeping it simple with direct arrays.
    private var strokes: [Stroke] = []
    private var nodes: [Node] = []
    private var connections: [Connection] = []

    private var committedVertices: [InkVertex] = []
    private var needsRedraw = true

    /// Camera for pan and zoom. M2: world-space coordinates.
    public var camera = Camera()

    /// M2 prototype: Draw mode vs Lasso mode for node creation.
    public enum DrawMode {
        case draw
        case lasso
    }

    /// Current drawing mode.
    public var drawMode: DrawMode = .draw

    /// Public accessor for the nodes list (read-only for UI display).
    public var allNodes: [Node] { nodes }

    /// Public accessor for connections list (read-only for UI display).
    public var allConnections: [Connection] { connections }

    /// M2 prototype: Current lasso path (in view space) while drawing the selection.
    private var lassoPath: [Vec2] = []

    /// M2 prototype: Index of node currently being dragged, if any.
    private var draggingNodeIndex: Int?

    /// M2 prototype: Offset from drag start to node center (for smooth dragging).
    private var dragOffset: Vec2 = .zero

    /// M2 prototype: ID of currently selected node (for highlighting).
    public var selectedNodeId: UUID?

    /// M2 prototype: ID of currently selected connection (for highlighting and deletion).
    public var selectedConnectionId: UUID?

    /// M2 prototype: Active resize handle being dragged, if any.
    private var activeResizeHandle: Bool = false

    /// M2 prototype: Original bounds before resize started (for proportional scaling).
    private var resizeStartBounds: Rect?

    /// M2 prototype: Original strokes before resize started (for smooth scaling).
    private var resizeStartStrokes: [Stroke]?

    /// M2 prototype: Anchor point for proportional resize (opposite corner).
    private var resizeAnchorPoint: Vec2?

    /// M2 prototype: Current node dimensions during resize (for UI display).
    /// Returns (width, height) in points, or nil if not resizing.
    public var resizingNodeDimensions: (width: Double, height: Double)? {
        guard let selectedId = selectedNodeId,
              activeResizeHandle != nil,
              let node = nodes.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Convert world space dimensions to view space points
        let widthPoints = node.bounds.width * Double(camera.zoom)
        let heightPoints = node.bounds.height * Double(camera.zoom)
        return (widthPoints, heightPoints)
    }

    /// M2 prototype: Callback when a closed shape is detected (auto-node suggestion).
    public var onClosedShapeDetected: ((Int) -> Void)?  // Passes stroke index

    /// M2 prototype: Callback when a closed shape contains nodes (for absorb choice).
    public var onClosedShapeWithNodes: ((Int, [Int]) -> Void)?  // Passes stroke index and node indices

    /// M2 prototype: Callback when lasso selects a node (for absorb/separate choice).
    public var onNodeLassoed: ((UUID, [Stroke]) -> Void)?  // Passes node ID and selected strokes

    /// M2 prototype: Callback when a node is selected (for highlighting).
    public var onNodeSelected: ((UUID?) -> Void)?  // Passes node ID or nil if deselected

    /// M2 prototype: Callback when a connection is selected (for highlighting and deletion).
    public var onConnectionSelected: ((UUID?) -> Void)?  // Passes connection ID or nil if deselected

    /// M2 prototype: Callback when nodes change (for UI refresh).
    public var onNodesChanged: (([Node]) -> Void)?

    /// Callback when a stroke is committed (for sync).
    public var onStrokeCommitted: ((Stroke) -> Void)?

    /// Callback when a stroke is deleted (for sync).
    public var onStrokeDeleted: ((UUID) -> Void)?

    /// Callback when a node is created (for sync).
    public var onNodeCreated: ((Node) -> Void)?

    /// Callback when a node is created with stroke deletions (for sync).
    public var onNodeCreatedWithStrokeDeletions: ((Node, [UUID]) -> Void)?

    /// Callback when a node is updated (for sync).
    public var onNodeUpdated: ((Node) -> Void)?

    /// Callback when a node is deleted (for sync).
    public var onNodeDeleted: ((UUID) -> Void)?

    /// Callback when a connection is created (for sync).
    public var onConnectionCreated: ((Connection) -> Void)?

    /// Callback when a connection is deleted (for sync).
    public var onConnectionDeleted: ((UUID) -> Void)?

    /// Current ink settings. Changing this affects the next stroke.
    public var style: InkStyle = .pen

    /// Toggle to feel what prediction is worth. Bound to a switch in the demo app.
    public var predictionEnabled: Bool {
        get { collector.predictionEnabled }
        set { collector.predictionEnabled = newValue }
    }

    /// Called after every frame so the demo app can update its HUD.
    public var onStatsUpdate: ((HUDStats) -> Void)?

    public struct HUDStats {
        public var strokeCount = 0
        public var liveSamples = 0
        public var predictedSamples = 0
        public var estimateCorrections = 0
        public var liveVertices = 0
        public var committedVertices = 0
        public var cpuFrameMilliseconds: Double = 0
        public var displayFPS: Double = 0

        public init() {}

        public init(
            strokeCount: Int = 0,
            liveSamples: Int = 0,
            predictedSamples: Int = 0,
            estimateCorrections: Int = 0,
            liveVertices: Int = 0,
            committedVertices: Int = 0,
            cpuFrameMilliseconds: Double = 0,
            displayFPS: Double = 0
        ) {
            self.strokeCount = strokeCount
            self.liveSamples = liveSamples
            self.predictedSamples = predictedSamples
            self.estimateCorrections = estimateCorrections
            self.liveVertices = liveVertices
            self.committedVertices = committedVertices
            self.cpuFrameMilliseconds = cpuFrameMilliseconds
            self.displayFPS = displayFPS
        }
    }

    private var lastFrameTimestamp: CFTimeInterval = 0
    private var smoothedFPS: Double = 0

    /// Text recognition service for handwriting recognition.
    private let recognitionService = TextRecognitionService()

    // MARK: - Lifecycle

    public init?(frame: CGRect, renderer: InkRenderer? = InkRenderer()) {
        guard let renderer else { return nil }
        self.renderer = renderer
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:renderer:)")
    }

    private func configure() {
        // M2: enable multitouch for pan/zoom gestures while Pencil draws
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .clear

        metalLayer.device = renderer.metalDevice
        metalLayer.pixelFormat = .bgra8Unorm
        // We render offscreen and composite to the drawable, never sampling it.
        metalLayer.framebufferOnly = true
        // Default is 3. Triple buffering adds a frame of latency; for ink, trade
        // throughput for responsiveness.
        metalLayer.maximumDrawableCount = 2

        // One-finger pan gesture (for easy navigation)
        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = self
        addGestureRecognizer(oneFingerPan)

        // Two-finger pan gesture
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        // Pinch-to-zoom gesture
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        // Tap gesture for node selection
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)

        let link = CADisplayLink(target: self, selector: #selector(step))
        // ProMotion parks at 60 Hz unless you ask for more. The minimum stays at 60
        // so this is still valid on non-ProMotion iPads, which cap at 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    deinit {
        displayLink?.invalidate()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        needsRedraw = true
    }

    // MARK: - Touches

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        // Handle finger touches for node selection and resize
        if touch.type == .direct {
            let location = touch.location(in: self)
            let viewPoint = Vec2(Double(location.x), Double(location.y))

            // Check if tapping on the resize handle of the selected node
            if let selectedId = selectedNodeId,
               isNearResizeHandle(viewPoint: viewPoint, for: selectedId) {
                activeResizeHandle = true
                if let node = nodes.first(where: { $0.id == selectedId }) {
                    resizeStartBounds = node.bounds
                    resizeStartStrokes = node.strokes  // Store original strokes
                }
                resizeAnchorPoint = nil  // Will be set on first resize
                needsRedraw = true
                return
            }

            // Check if tapping on a node
            let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
            let worldPoint = camera.viewToWorld(viewPoint, viewSize: viewSize)

            if let nodeIndex = nodes.firstIndex(where: { $0.contains(worldPoint) }) {
                // Select the node
                selectedNodeId = nodes[nodeIndex].id
                onNodeSelected?(nodes[nodeIndex].id)
                needsRedraw = true
                return
            }

            // Tapped on background - deselect
            if selectedNodeId != nil || selectedConnectionId != nil {
                selectedNodeId = nil
                selectedConnectionId = nil
                onNodeSelected?(nil)
                onConnectionSelected?(nil)
                rebuildCommittedGeometry()  // Rebuild to remove resize handles
                needsRedraw = true
            }

            return
        }

        // Only accept Apple Pencil touches for drawing
        guard touch.type == .pencil else { return }

        switch drawMode {
        case .draw:
            collector.begin(touch, in: self)
        case .lasso:
            lassoPath.removeAll()
            let location = touch.preciseLocation(in: self)
            lassoPath.append(Vec2(Double(location.x), Double(location.y)))
        }
        needsRedraw = true
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        // Handle finger drags for resize
        if touch.type == .direct {
            if activeResizeHandle,
               let selectedId = selectedNodeId {
                // Get all coalesced touches for smoother updates
                let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]

                // Use the last coalesced touch for the most up-to-date position
                if let lastTouch = coalescedTouches.last {
                    let location = lastTouch.location(in: self)
                    let viewPoint = Vec2(Double(location.x), Double(location.y))

                    // Perform resize
                    resizeNode(id: selectedId, endPoint: viewPoint)
                    needsRedraw = true
                }
            }
            return
        }

        // Only accept Apple Pencil touches for drawing
        guard touch.type == .pencil else { return }

        switch drawMode {
        case .draw:
            collector.update(with: touch, event: event, in: self)
        case .lasso:
            let location = touch.preciseLocation(in: self)
            lassoPath.append(Vec2(Double(location.x), Double(location.y)))
        }
        needsRedraw = true
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        // Handle finger touch end for resize
        if touch.type == .direct {
            if activeResizeHandle {
                // Finish resize
                activeResizeHandle = false
                resizeStartBounds = nil
                resizeStartStrokes = nil
                resizeAnchorPoint = nil
                onNodesChanged?(nodes)  // Notify UI

                // Notify sync if a node was resized
                if let selectedId = selectedNodeId,
                   let node = nodes.first(where: { $0.id == selectedId }) {
                    onNodeUpdated?(node)
                }

                needsRedraw = true
            }
            return
        }

        // Only accept Apple Pencil touches for drawing
        guard touch.type == .pencil else { return }

        switch drawMode {
        case .draw:
            let points = collector.finish(touch, in: self)
            commit(points)
        case .lasso:
            // Close the lasso and create a node from selected strokes
            let location = touch.preciseLocation(in: self)
            lassoPath.append(Vec2(Double(location.x), Double(location.y)))
            finalizeLasso()
            lassoPath.removeAll()
        }
        needsRedraw = true
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        collector.reset()
        lassoPath.removeAll()
        needsRedraw = true
    }

    /// The correction callback. Without this, pressure data is quietly wrong.
    public override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            collector.applyEstimatedUpdate(touch)
        }
        needsRedraw = true
    }

    // MARK: - Commit

    /// Convert points from view space (where touches happen) to world space (where strokes live).
    private func toWorldSpace(_ points: [InkPoint]) -> [InkPoint] {
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        return points.map { point in
            var worldPoint = point
            worldPoint.position = camera.viewToWorld(point.position, viewSize: viewSize)
            return worldPoint
        }
    }

    private func commit(_ points: [InkPoint]) {
        guard points.count > 0 else {
            collector.reset()
            return
        }
        // Convert from view space to world space before storing
        let worldPoints = toWorldSpace(points)

        // M2 prototype: Check for draw-to-connect gesture
        // If stroke starts in one node and ends in another, create a connection
        if drawMode == .draw, let firstPoint = worldPoints.first?.position, let lastPoint = worldPoints.last?.position {
            // Find which nodes contain the first and last points
            let startNodeIndex = nodes.firstIndex { $0.contains(firstPoint) }
            let endNodeIndex = nodes.firstIndex { $0.contains(lastPoint) }

            // If we have two different nodes, create a connection instead of a stroke
            if let startIdx = startNodeIndex, let endIdx = endNodeIndex, startIdx != endIdx {
                let sourceId = nodes[startIdx].id
                let targetId = nodes[endIdx].id

                if addConnection(from: sourceId, to: targetId) {
                    // Connection created successfully - rebuild geometry to show it
                    rebuildCommittedGeometry()
                    needsRedraw = true
                    collector.reset()
                    return  // Don't create a stroke
                }
            }
        }

        // Normal stroke creation (not a connection)
        let stroke = Stroke(points: worldPoints, style: style)
        strokes.append(stroke)

        // Notify sync that a stroke was committed
        onStrokeCommitted?(stroke)

        // Append this stroke's geometry to the committed buffer rather than
        // re-tessellating every stroke. M2 replaces this with tile rasterisation.
        let resampled = StrokeSmoother.resample(worldPoints)
        committedVertices.append(contentsOf: Tessellator.tessellate(resampled, style: stroke.style))
        renderer.setCommittedGeometry(committedVertices)
        renderer.setLiveGeometry([])

        // M2 prototype: Auto-detect closed shapes for node creation
        if drawMode == .draw && isClosedShape(stroke) {
            let strokeIndex = strokes.count - 1

            // Check if there are nodes inside this closed shape
            let boundaryPolygon = stroke.points.map { $0.position }
            var containedNodeIndices: [Int] = []
            for (i, node) in nodes.enumerated() {
                if pointInPolygon(node.bounds.center, polygon: boundaryPolygon) {
                    containedNodeIndices.append(i)
                }
            }

            // Call appropriate callback based on whether nodes are inside
            if !containedNodeIndices.isEmpty {
                onClosedShapeWithNodes?(strokeIndex, containedNodeIndices)
            } else {
                onClosedShapeDetected?(strokeIndex)
            }
        }

        collector.reset()
        needsRedraw = true
    }

    /// Detect if a stroke forms a closed shape (endpoints close together).
    private func isClosedShape(_ stroke: Stroke) -> Bool {
        guard stroke.points.count > 5 else { return false }  // Need minimum length

        let start = stroke.points.first!.position
        let end = stroke.points.last!.position
        let distance = start.distance(to: end)

        // Calculate the stroke's approximate size
        guard let bounds = stroke.bounds else { return false }
        let size = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)

        // Endpoints should be close relative to the stroke size (relaxed threshold)
        let closureThreshold = size * 0.25  // 25% of stroke size
        guard distance < closureThreshold else { return false }

        // Filter out letter-sized circles (likely "o", "O", "0")
        // Check if there are similar-sized strokes nearby (indicating text)
        if isLikelyLetter(stroke, size: size) {
            return false
        }

        return true
    }

    /// Heuristic to detect if a small circle is likely a letter (o, O, 0) based on nearby strokes.
    private func isLikelyLetter(_ stroke: Stroke, size: Double) -> Bool {
        // Only check small circles (typical letter size)
        let maxLetterSize = 60.0  // Maximum size for a letter at typical handwriting scale
        guard size < maxLetterSize else { return false }

        guard let strokeBounds = stroke.bounds else { return false }
        let strokeCenter = Vec2(
            strokeBounds.min.x + (strokeBounds.max.x - strokeBounds.min.x) / 2,
            strokeBounds.min.y + (strokeBounds.max.y - strokeBounds.min.y) / 2
        )

        // Look for nearby strokes of similar size (indicating text)
        let searchRadius = size * 3.0  // Look within 3x the stroke size
        var nearbyStrokesCount = 0

        for otherStroke in strokes {
            guard let otherBounds = otherStroke.bounds else { continue }

            let otherCenter = Vec2(
                otherBounds.min.x + (otherBounds.max.x - otherBounds.min.x) / 2,
                otherBounds.min.y + (otherBounds.max.y - otherBounds.min.y) / 2
            )

            let distanceToOther = strokeCenter.distance(to: otherCenter)

            // Skip the stroke itself
            if distanceToOther < 0.1 { continue }

            // Check if nearby and similar size
            if distanceToOther < searchRadius {
                let otherSize = max(otherBounds.max.x - otherBounds.min.x, otherBounds.max.y - otherBounds.min.y)
                let sizeRatio = otherSize / size

                // Similar size (within 50% - 200% range)
                if sizeRatio > 0.5 && sizeRatio < 2.0 {
                    nearbyStrokesCount += 1

                    // If we find 2+ similar-sized strokes nearby, likely text
                    if nearbyStrokesCount >= 2 {
                        return true
                    }
                }
            }
        }

        return false
    }

    // MARK: - Node Interaction

    /// Convert a stroke at the given index into a node.
    /// The stroke is treated as a boundary shape - any strokes inside it are included in the node.
    /// The boundary stroke itself is replaced with a clean rectangle outline.
    /// If there are nodes inside, creates an empty node (no auto-absorb of nodes).
    /// Convert a stroke to a node, creating an empty container.
    public func convertStrokeToNode(at index: Int) {
        guard index >= 0 && index < strokes.count else { return }

        let boundaryStroke = strokes[index]

        // Validate this is actually a closed shape
        // If not, the index might be stale, so don't proceed
        guard isClosedShape(boundaryStroke) else {
            print("⚠️ Stroke at index \(index) is not a closed shape, index may be stale")
            return
        }

        // Use the boundary stroke's points as a polygon
        let boundaryPolygon = boundaryStroke.points.map { $0.position }

        // Find all strokes INSIDE the boundary (excluding the boundary itself)
        var containedStrokes: [Stroke] = []
        var indicesToRemove: [Int] = [index]  // Always remove the boundary

        // Check for strokes inside the boundary
        for (i, stroke) in strokes.enumerated() {
            // Skip the boundary stroke itself
            guard i != index else { continue }

            // Check if this stroke is inside the boundary
            if isStrokeInsideLasso(stroke, lasso: boundaryPolygon) {
                containedStrokes.append(stroke)
                indicesToRemove.append(i)
            }
        }

        // Create node - absorb loose strokes if any, otherwise empty
        let bounds: Rect
        let node: Node

        if !containedStrokes.isEmpty {
            // If strokes inside, absorb them
            bounds = Node.computeBounds(containedStrokes)!
            node = Node(strokes: containedStrokes, bounds: bounds, boundaryStroke: boundaryStroke)
        } else {
            // Empty node - use the boundary stroke's bounds
            bounds = Node.computeBounds([boundaryStroke])!
            node = Node(strokes: [], bounds: bounds, boundaryStroke: boundaryStroke)
        }

        nodes.append(node)

        // Collect stroke IDs BEFORE removing them
        var deletedStrokeIds: [UUID] = []
        for i in indicesToRemove {
            if i >= 0 && i < strokes.count {
                deletedStrokeIds.append(strokes[i].id)
            }
        }

        print("🗑 convertStrokeToNode: deleting \(deletedStrokeIds.count) strokes: \(deletedStrokeIds)")

        // Remove all strokes (boundary + contained) from the main list
        // Sort indices in descending order to avoid index shifting during removal
        for i in indicesToRemove.sorted(by: >) {
            if i >= 0 && i < strokes.count {
                strokes.remove(at: i)
            }
        }

        // Notify sync about node creation with stroke deletions in one atomic message
        onNodeCreatedWithStrokeDeletions?(node, deletedStrokeIds)

        // Rebuild geometry
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    /// Convert a stroke to a node and absorb all nodes inside it.
    public func convertStrokeToNodeWithAbsorb(at index: Int) {
        guard index >= 0 && index < strokes.count else { return }

        let boundaryStroke = strokes[index]

        // Use the boundary stroke's points as a polygon
        let boundaryPolygon = boundaryStroke.points.map { $0.position }

        // Find all strokes and nodes inside the boundary
        var allStrokes: [Stroke] = []
        var indicesToRemove: [Int] = [index]  // Always remove the boundary
        var nodesToRemove: [Int] = []

        // Check for strokes inside the boundary
        for (i, stroke) in strokes.enumerated() {
            guard i != index else { continue }

            if isStrokeInsideLasso(stroke, lasso: boundaryPolygon) {
                allStrokes.append(stroke)
                indicesToRemove.append(i)
            }
        }

        // Check for nodes inside and collect their strokes
        var enclosedNodeIds = Set<UUID>()
        for (i, node) in nodes.enumerated() {
            if pointInPolygon(node.bounds.center, polygon: boundaryPolygon) {
                allStrokes.append(contentsOf: node.strokes)
                nodesToRemove.append(i)
                enclosedNodeIds.insert(node.id)
            }
        }

        // Create merged node with all strokes
        // If there are no strokes, use the boundary stroke itself to compute bounds
        var mergedNodeId: UUID?
        var newNode: Node?
        if let bounds = Node.computeBounds(allStrokes.isEmpty ? [boundaryStroke] : allStrokes) {
            let node = Node(strokes: allStrokes, bounds: bounds, boundaryStroke: boundaryStroke)
            mergedNodeId = node.id
            newNode = node
            nodes.append(node)
        }

        // Handle connections if we absorbed any nodes
        if !enclosedNodeIds.isEmpty {
            // Collect node IDs before removal for sync
            let deletedNodeIds = nodesToRemove.map { nodes[$0].id }

            // Remove absorbed nodes (in reverse order)
            for i in nodesToRemove.sorted(by: >) {
                nodes.remove(at: i)
            }

            // Notify sync about deleted nodes
            for nodeId in deletedNodeIds {
                onNodeDeleted?(nodeId)
            }

            // Collect external connections before removing nodes
            var externalOutgoingTargets = Set<UUID>()
            var externalIncomingSources = Set<UUID>()

            for conn in connections {
                // Outgoing: enclosed → external
                if enclosedNodeIds.contains(conn.from) && !enclosedNodeIds.contains(conn.to) {
                    externalOutgoingTargets.insert(conn.to)
                }
                // Incoming: external → enclosed
                if !enclosedNodeIds.contains(conn.from) && enclosedNodeIds.contains(conn.to) {
                    externalIncomingSources.insert(conn.from)
                }
            }

            // Remove ALL connections involving enclosed nodes
            connections.removeAll { conn in
                enclosedNodeIds.contains(conn.from) || enclosedNodeIds.contains(conn.to)
            }

            // Remove from nodes' connection arrays
            for nodeId in enclosedNodeIds {
                for i in nodes.indices {
                    nodes[i].connections.removeAll { $0 == nodeId }
                }
            }

            // Create new connections from merged node to external nodes
            if let mergedId = mergedNodeId, let mergedIndex = nodes.firstIndex(where: { $0.id == mergedId }) {
                // Add outgoing connections (merged → external)
                for targetId in externalOutgoingTargets {
                    let connection = Connection(from: mergedId, to: targetId)
                    connections.append(connection)
                    if !nodes[mergedIndex].connections.contains(targetId) {
                        nodes[mergedIndex].connections.append(targetId)
                    }
                }

                // Add incoming connections (external → merged)
                for sourceId in externalIncomingSources {
                    let connection = Connection(from: sourceId, to: mergedId)
                    connections.append(connection)
                    // Also update the source node's connections array
                    if let sourceIndex = nodes.firstIndex(where: { $0.id == sourceId }) {
                        if !nodes[sourceIndex].connections.contains(mergedId) {
                            nodes[sourceIndex].connections.append(mergedId)
                        }
                    }
                }

                // Sync updates to external nodes that now have connections to the merged node
                for sourceId in externalIncomingSources {
                    if let sourceNode = nodes.first(where: { $0.id == sourceId }) {
                        onNodeUpdated?(sourceNode)
                    }
                }

                // Update newNode to reference the updated node with connections
                newNode = nodes.first(where: { $0.id == mergedId })
            }
        } else {
            // No nodes to absorb, just remove absorbed nodes if any
            for i in nodesToRemove.sorted(by: >) {
                nodes.remove(at: i)
            }
        }

        // Remove all strokes from the main list and sync deletions
        var deletedStrokeIds: [UUID] = []
        for i in indicesToRemove.sorted(by: >) {
            deletedStrokeIds.append(strokes[i].id)
            strokes.remove(at: i)
        }

        print("🗑 convertStrokeToNodeWithAbsorb: deleting \(deletedStrokeIds.count) strokes: \(deletedStrokeIds)")

        // Notify sync about node creation with stroke deletions in one atomic message
        if let node = newNode {
            onNodeCreatedWithStrokeDeletions?(node, deletedStrokeIds)
        }

        // Rebuild geometry
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    /// Find the index of the node at the given point in view space (returns topmost if overlapping).
    /// Expands hit area for small nodes to make them easier to select.
    private func nodeAt(viewPoint: Vec2) -> Int? {
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        let worldPoint = camera.viewToWorld(viewPoint, viewSize: viewSize)

        // Minimum hit area in world space (makes small nodes easier to tap)
        let minHitSize = 80.0 / Double(camera.zoom)  // 80 points in view space

        // Check nodes in reverse order (topmost first)
        for (index, node) in nodes.enumerated().reversed() {
            // Expand bounds for small nodes
            let expandedBounds: Rect
            if node.bounds.width < minHitSize || node.bounds.height < minHitSize {
                let expandX = max(0, (minHitSize - node.bounds.width) / 2)
                let expandY = max(0, (minHitSize - node.bounds.height) / 2)
                expandedBounds = Rect(
                    x: node.bounds.x - expandX,
                    y: node.bounds.y - expandY,
                    width: node.bounds.width + expandX * 2,
                    height: node.bounds.height + expandY * 2
                )
            } else {
                expandedBounds = node.bounds
            }

            if expandedBounds.contains(worldPoint) {
                return index
            }
        }
        return nil
    }

    /// Find a connection at the given view point (within tap distance).
    private func connectionAt(viewPoint: Vec2) -> Connection? {
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        let worldPoint = camera.viewToWorld(viewPoint, viewSize: viewSize)

        // Tap threshold in world space (20 points in view space)
        let tapThreshold = 20.0 / Double(camera.zoom)

        // Check each connection
        for connection in connections {
            guard let sourceNode = nodes.first(where: { $0.id == connection.from }),
                  let targetNode = nodes.first(where: { $0.id == connection.to }) else {
                continue
            }

            let start = sourceNode.bounds.center
            let end = targetNode.bounds.center

            // Calculate distance from point to line segment
            let distance = distanceFromPointToLineSegment(point: worldPoint, start: start, end: end)

            if distance < tapThreshold {
                return connection
            }
        }

        return nil
    }

    /// Calculate distance from a point to a line segment.
    private func distanceFromPointToLineSegment(point: Vec2, start: Vec2, end: Vec2) -> Double {
        let lineVec = end - start
        let pointVec = point - start
        let lineLength = lineVec.length

        guard lineLength > 0 else {
            return point.distance(to: start)
        }

        // Project point onto line, clamped to segment
        let t = max(0, min(1, (pointVec.x * lineVec.x + pointVec.y * lineVec.y) / (lineLength * lineLength)))
        let projection = start + lineVec * t

        return point.distance(to: projection)
    }

    /// Detect and absorb strokes inside a specific node (one-time action).
    public func detectStrokesInNode(nodeId: UUID) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeId }) else { return }

        let node = nodes[nodeIndex]
        var strokesToAbsorb: [Stroke] = []
        var remainingStrokes: [Stroke] = []

        // Find all strokes inside this node's bounds
        for stroke in strokes {
            // Check if most of the stroke is inside this node's bounds
            var insideCount = 0
            let sampleCount = min(stroke.points.count, 10)
            let step = max(1, stroke.points.count / sampleCount)

            for i in stride(from: 0, to: stroke.points.count, by: step) {
                if node.bounds.contains(stroke.points[i].position) {
                    insideCount += 1
                }
            }

            // If more than half the samples are inside, mark for absorption
            if insideCount > sampleCount / 2 {
                strokesToAbsorb.append(stroke)
            } else {
                remainingStrokes.append(stroke)
            }
        }

        // Absorb the strokes into the node (keep original bounds)
        if !strokesToAbsorb.isEmpty {
            nodes[nodeIndex].strokes.append(contentsOf: strokesToAbsorb)
            // Debug logging - uncomment if needed
            // print("🟠 [MetalInkView] After append: nodes[\(nodeIndex)] has \(nodes[nodeIndex].strokes.count) strokes")

            // Don't clear recognized text - let user re-recognize manually to add new words
            // This way "david" stays, and clicking recognize again will find "david hello"

            // Don't recalculate bounds - keep the original circle size
            strokes = remainingStrokes

            // Notify sync about deleted strokes
            for stroke in strokesToAbsorb {
                onStrokeDeleted?(stroke.id)
            }

            // Notify sync about updated node
            onNodeUpdated?(nodes[nodeIndex])

            rebuildCommittedGeometry()
            needsRedraw = true
        }

        // Always notify UI to refresh (even if nothing changed)
        // Debug logging - uncomment if needed
        // print("🟠 [MetalInkView] Before callback: nodes[\(nodeIndex)] has \(nodes[nodeIndex].strokes.count) strokes")
        onNodesChanged?(nodes)
        // print("🟠 [MetalInkView] After callback: nodes[\(nodeIndex)] has \(nodes[nodeIndex].strokes.count) strokes")
    }

    // MARK: - Text Recognition

    /// Recognize handwritten text in a specific node using Vision Framework.
    /// Updates the node's recognizedText property and notifies UI.
    public func recognizeTextInNode(nodeId: UUID) async {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeId }) else { return }

        let result = await recognitionService.recognizeText(from: nodes[nodeIndex])

        switch result {
        case .success(let text, let confidence, let source):
            // Convert source enum to codable version
            let sourceData: RecognizedText.RecognitionSourceData
            switch source {
            case .vision(let conf):
                sourceData = .vision(confidence: conf)
            case .customModel(let conf):
                sourceData = .customModel(confidence: conf)
            case .correctionHistory(let conf):
                sourceData = .correctionHistory(matchConfidence: conf)
            }

            // Update node with recognized text
            nodes[nodeIndex].recognizedText = RecognizedText(
                text: text,
                confidence: confidence,
                source: sourceData
            )

            // Notify UI
            onNodesChanged?(nodes)

        case .failure(let error):
            print("❌ Text recognition failed for node \(nodeId): \(error)")
        }
    }

    /// Delete a node by its ID.
    public func deleteNode(id nodeId: UUID) {
        if let index = nodes.firstIndex(where: { $0.id == nodeId }) {
            // Get the strokes from the node and add them back to the canvas
            let nodeStrokes = nodes[index].strokes
            strokes.append(contentsOf: nodeStrokes)

            // Remove the node
            nodes.remove(at: index)

            // Notify sync that a node was deleted
            onNodeDeleted?(nodeId)

            // Remove all connections to/from this node
            removeAllConnections(for: nodeId)

            // Rebuild geometry
            rebuildCommittedGeometry()
            needsRedraw = true
        }
    }

    // MARK: - Node Resize

    /// Get the bottom-right resize handle position for a given node (in view space).
    /// Returns nil if the node is not found.
    private func resizeHandlePosition(for nodeId: UUID) -> Vec2? {
        guard let node = nodes.first(where: { $0.id == nodeId }) else { return nil }

        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        let bounds = node.bounds

        // Bottom-right corner in world space, converted to view space
        let bottomRight = camera.worldToView(Vec2(bounds.maxX, bounds.maxY), viewSize: viewSize)
        return bottomRight
    }

    /// Check if a point in view space is near the bottom-right resize handle.
    /// Returns true if near the handle, false otherwise.
    /// Handle hit area is 20 points in view space.
    private func isNearResizeHandle(viewPoint: Vec2, for nodeId: UUID) -> Bool {
        guard let handlePosition = resizeHandlePosition(for: nodeId) else { return false }

        let hitRadius = 20.0  // 20 points hit radius
        let distance = viewPoint.distance(to: handlePosition)
        return distance <= hitRadius
    }

    /// Resize a node by dragging the bottom-right handle to endPoint (view space).
    /// Scales proportionally maintaining aspect ratio - handle moves diagonally (like GoodNotes).
    private func resizeNode(id nodeId: UUID, endPoint: Vec2) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeId }) else { return }

        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))

        // Use the original bounds from when resize started
        guard let oldBounds = resizeStartBounds else { return }

        // Center point stays fixed - node scales from center
        let center = oldBounds.center

        // Calculate original aspect ratio
        let aspectRatio = oldBounds.width / oldBounds.height

        // Convert drag point to world space
        let endWorldPoint = camera.viewToWorld(endPoint, viewSize: viewSize)

        // Calculate how far the handle is from center
        let deltaFromCenter = endWorldPoint - center

        // Calculate the average scale based on both dimensions
        // This determines how much bigger/smaller the node should be
        let scaleFromX = abs(deltaFromCenter.x) / (oldBounds.width / 2.0)
        let scaleFromY = abs(deltaFromCenter.y) / (oldBounds.height / 2.0)

        // Use the average of both scales to get smooth proportional scaling
        var scale = (scaleFromX + scaleFromY) / 2.0

        // Enforce minimum size (40x40 points in world space)
        let minSizeWorld = 40.0 / Double(camera.zoom)
        let minScale = minSizeWorld / min(oldBounds.width, oldBounds.height)
        scale = max(scale, minScale)

        // Calculate new dimensions maintaining aspect ratio
        let newWidth = oldBounds.width * scale
        let newHeight = oldBounds.height * scale

        // New bounds centered at the same center point
        let newBounds = Rect(
            x: center.x - newWidth / 2.0,
            y: center.y - newHeight / 2.0,
            width: newWidth,
            height: newHeight
        )

        // Scale all strokes uniformly
        var scaledStrokes: [Stroke] = []

        // Use the original strokes stored when resize started
        guard let originalStrokes = resizeStartStrokes else { return }

        for stroke in originalStrokes {
            var scaledPoints: [InkPoint] = []
            for point in stroke.points {
                // Scale uniformly from center point using original positions
                let offsetFromCenter = point.position - center
                let scaledOffset = offsetFromCenter * scale
                let newPosition = center + scaledOffset

                var newPoint = point
                newPoint.position = newPosition
                scaledPoints.append(newPoint)
            }
            scaledStrokes.append(Stroke(points: scaledPoints, style: stroke.style))
        }

        // Update node
        nodes[nodeIndex].strokes = scaledStrokes
        nodes[nodeIndex].bounds = newBounds

        // Rebuild geometry
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    // MARK: - Lasso Selection

    /// Finalize the lasso: find strokes/nodes inside, offer options.
    private func finalizeLasso() {
        guard lassoPath.count > 3 else { return }  // Need at least a small closed shape

        // Convert lasso path from view space to world space
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        let worldLasso = lassoPath.map { camera.viewToWorld($0, viewSize: viewSize) }

        // Check if lasso overlaps any existing nodes
        var nodesInside: [Int] = []
        for (index, node) in nodes.enumerated() {
            // Check if node center is inside lasso
            if pointInPolygon(node.bounds.center, polygon: worldLasso) {
                nodesInside.append(index)
            }
        }

        // If we found 2+ nodes, absorb smaller one(s) into the largest
        if nodesInside.count >= 2 {
            // Find the largest node by area
            let largestIndex = nodesInside.max(by: { idx1, idx2 in
                let area1 = nodes[idx1].bounds.width * nodes[idx1].bounds.height
                let area2 = nodes[idx2].bounds.width * nodes[idx2].bounds.height
                return area1 < area2
            })!

            // Collect strokes from all smaller nodes
            var strokesToAbsorb: [Stroke] = []
            for index in nodesInside {
                if index != largestIndex {
                    strokesToAbsorb.append(contentsOf: nodes[index].strokes)
                }
            }

            // Trigger callback for absorb/separate choice
            if !strokesToAbsorb.isEmpty {
                onNodeLassoed?(nodes[largestIndex].id, strokesToAbsorb)
                return
            }
        }

        // If we found exactly 1 node, offer to absorb loose strokes into it
        if nodesInside.count == 1 {
            let nodeIndex = nodesInside[0]
            // Find strokes inside the lasso
            var selectedStrokes: [Stroke] = []
            for stroke in strokes {
                if isStrokeInsideLasso(stroke, lasso: worldLasso) {
                    selectedStrokes.append(stroke)
                }
            }

            // Trigger callback for absorb/separate choice
            if !selectedStrokes.isEmpty {
                onNodeLassoed?(nodes[nodeIndex].id, selectedStrokes)
                return
            }
        }

        // No nodes selected - normal lasso behavior: create new node
        var selectedStrokes: [Stroke] = []
        var remainingStrokes: [Stroke] = []

        for stroke in strokes {
            if isStrokeInsideLasso(stroke, lasso: worldLasso) {
                selectedStrokes.append(stroke)
            } else {
                remainingStrokes.append(stroke)
            }
        }

        guard !selectedStrokes.isEmpty else { return }

        // Create a node from the selected strokes
        if let bounds = Node.computeBounds(selectedStrokes) {
            let node = Node(strokes: selectedStrokes, bounds: bounds)
            nodes.append(node)

            // Remove selected strokes from the main stroke list
            strokes = remainingStrokes

            // Rebuild committed vertices without the selected strokes
            rebuildCommittedGeometry()
        }
    }

    /// Absorb strokes into an existing node.
    /// If absorbing another node's strokes, the smaller node is removed and bounds are recalculated.
    public func absorbIntoNode(nodeId: UUID, strokes strokesToAbsorb: [Stroke]) {
        guard let nodeIndex = nodes.firstIndex(where: { $0.id == nodeId }) else {
            return
        }

        // Check if we're absorbing strokes from another node
        // Build a set of stroke identifiers for faster lookup
        var strokeIdentifiers = Set<StrokeIdentifier>()
        for stroke in strokesToAbsorb {
            strokeIdentifiers.insert(StrokeIdentifier(stroke: stroke))
        }

        var nodesToRemove: [Int] = []
        for (index, otherNode) in nodes.enumerated() {
            guard index != nodeIndex else { continue }

            // Check if all of this node's strokes are being absorbed
            let allStrokesAbsorbed = otherNode.strokes.allSatisfy { nodeStroke in
                strokeIdentifiers.contains(StrokeIdentifier(stroke: nodeStroke))
            }

            if allStrokesAbsorbed {
                nodesToRemove.append(index)
            }
        }

        // Add strokes to the target node
        nodes[nodeIndex].strokes.append(contentsOf: strokesToAbsorb)

        // Recalculate bounds to encompass all strokes in the node
        if let newBounds = Node.computeBounds(nodes[nodeIndex].strokes) {
            nodes[nodeIndex].bounds = newBounds
        }

        // Handle connections for absorbed nodes
        // Remove all connections involving the absorbed node
        // Do this BEFORE removing the nodes so removeAllConnections can access them
        for index in nodesToRemove {
            let absorbedNodeId = nodes[index].id
            removeAllConnections(for: absorbedNodeId)
        }

        // Collect node IDs before removal for sync
        let deletedNodeIds = nodesToRemove.map { nodes[$0].id }

        // Remove absorbed nodes (in reverse order to avoid index shifting)
        for index in nodesToRemove.sorted(by: >) {
            nodes.remove(at: index)
        }

        // Notify sync about deleted nodes
        for nodeId in deletedNodeIds {
            onNodeDeleted?(nodeId)
        }

        // Remove these strokes from the main canvas
        var remainingStrokes: [Stroke] = []
        var absorbedStrokeIds: [UUID] = []
        for stroke in strokes {
            // Check if this stroke is one we're absorbing
            let isAbsorbed = strokeIdentifiers.contains(StrokeIdentifier(stroke: stroke))
            if !isAbsorbed {
                remainingStrokes.append(stroke)
            } else {
                absorbedStrokeIds.append(stroke.id)
            }
        }
        strokes = remainingStrokes

        // Notify sync about deleted strokes
        for strokeId in absorbedStrokeIds {
            onStrokeDeleted?(strokeId)
        }

        // Notify sync about updated node
        onNodeUpdated?(nodes[nodeIndex])

        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)  // Notify UI to refresh
    }

    /// Create a new node from strokes (separate operation).
    public func separateIntoNewNode(strokes strokesToSeparate: [Stroke]) {
        guard !strokesToSeparate.isEmpty else { return }

        if let bounds = Node.computeBounds(strokesToSeparate) {
            let node = Node(strokes: strokesToSeparate, bounds: bounds)
            nodes.append(node)

            // Remove these strokes from the main canvas
            var remainingStrokes: [Stroke] = []
            var separatedStrokeIds: [UUID] = []
            for stroke in strokes {
                let isSeparated = strokesToSeparate.contains { separatedStroke in
                    separatedStroke.points.count == stroke.points.count &&
                    separatedStroke.points.first?.position == stroke.points.first?.position
                }
                if !isSeparated {
                    remainingStrokes.append(stroke)
                } else {
                    separatedStrokeIds.append(stroke.id)
                }
            }
            strokes = remainingStrokes

            // Notify sync about deleted strokes
            for strokeId in separatedStrokeIds {
                onStrokeDeleted?(strokeId)
            }

            // Notify sync about created node
            onNodeCreated?(node)

            rebuildCommittedGeometry()
            needsRedraw = true
        }
    }

    /// Check if a stroke is inside the lasso polygon (uses bounding box + sampling).
    private func isStrokeInsideLasso(_ stroke: Stroke, lasso: [Vec2]) -> Bool {
        return GeometryManager.isStrokeInsideLasso(stroke, lasso: lasso)
    }

    private func pointInPolygon(_ point: Vec2, polygon: [Vec2]) -> Bool {
        return GeometryManager.pointInPolygon(point, polygon: polygon)
    }

    /// Rebuild committed geometry from current strokes (used after lasso selection).
    private func rebuildCommittedGeometry() {
        committedVertices = strokes.flatMap { stroke in
            Tessellator.tessellate(StrokeSmoother.resample(stroke.points), style: stroke.style)
        }

        // Add connection arrows (render before nodes so they appear underneath)
        for connection in connections {
            committedVertices.append(contentsOf: connectionArrowVertices(connection))
        }

        // Add node geometry: bounds + contained strokes
        for node in nodes {
            // Render node bounds as a thick outline
            committedVertices.append(contentsOf: nodeOutlineVertices(node))

            // Render strokes inside the node
            for stroke in node.strokes {
                committedVertices.append(contentsOf: Tessellator.tessellate(
                    StrokeSmoother.resample(stroke.points),
                    style: stroke.style
                ))
            }

            // Render resize handles if this node is selected
            if node.id == selectedNodeId {
                committedVertices.append(contentsOf: resizeHandleVertices(for: node))
            }
        }

        renderer.setCommittedGeometry(committedVertices)
    }

    /// Generate line vertices for the lasso path (in world space).
    private func lassoPathVertices() -> [InkVertex] {
        guard lassoPath.count > 1 else { return [] }

        // Convert lasso from view to world space
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
        let worldLasso = lassoPath.map { camera.viewToWorld($0, viewSize: viewSize) }

        // Create a stroke-like representation with fixed width
        let lassoPoints = worldLasso.map { point in
            InkPoint(
                position: point,
                force: 0.5,
                altitude: .pi / 2,
                azimuth: 0,
                timestamp: 0
            )
        }

        // Tessellate with a distinct color (blue for lasso)
        let lassoStyle = InkStyle(
            red: 0.2,
            green: 0.5,
            blue: 1.0,
            alpha: 0.7,
            pressure: PressureCurve(minWidth: 2, maxWidth: 2, exponent: 1.0, tiltBroadening: 0)
        )
        let resampled = StrokeSmoother.resample(lassoPoints)
        return Tessellator.tessellate(resampled, style: lassoStyle)
    }

    /// Generate vertices for a node's bounding box outline.
    private func nodeOutlineVertices(_ node: Node) -> [InkVertex] {
        let b = node.bounds
        let isSelected = (node.id == selectedNodeId)

        // Selected nodes get a brighter color and thicker outline
        let color = isSelected ? (0.9, 0.6, 0.2) : node.style.borderColor  // Orange for selected, blue for normal
        let width = isSelected ? node.style.borderWidth * 2.0 : node.style.borderWidth

        // Create four corners
        let corners = [
            Vec2(b.x, b.y),
            Vec2(b.x + b.width, b.y),
            Vec2(b.x + b.width, b.y + b.height),
            Vec2(b.x, b.y + b.height),
            Vec2(b.x, b.y)  // Close the loop
        ]

        // Convert to InkPoints with fixed pressure
        let points = corners.map { corner in
            InkPoint(
                position: corner,
                force: 0.5,
                altitude: .pi / 2,
                azimuth: 0,
                timestamp: 0
            )
        }

        // Tessellate the outline
        let outlineStyle = InkStyle(
            red: color.0,
            green: color.1,
            blue: color.2,
            alpha: 1.0,
            pressure: PressureCurve(minWidth: width, maxWidth: width, exponent: 1.0, tiltBroadening: 0)
        )
        let resampled = StrokeSmoother.resample(points)
        return Tessellator.tessellate(resampled, style: outlineStyle)
    }

    /// Generate vertices for the resize handle (bottom-right corner circle) for a selected node.
    private func resizeHandleVertices(for node: Node) -> [InkVertex] {
        let b = node.bounds
        let handleRadius = 10.0 / Double(camera.zoom)  // 10 points in view space, scaled by zoom

        // Bottom-right corner position in world space
        let center = Vec2(b.x + b.width, b.y + b.height)

        // Handle color (white with blue tint)
        let handleColor = (0.9, 0.9, 1.0)

        // Create a circle using 16 points
        let segments = 16
        var circlePoints: [InkPoint] = []

        for i in 0...segments {
            let angle = Double(i) * 2.0 * .pi / Double(segments)
            let x = center.x + handleRadius * cos(angle)
            let y = center.y + handleRadius * sin(angle)

            circlePoints.append(InkPoint(
                position: Vec2(x, y),
                force: 0.5,
                altitude: .pi / 2,
                azimuth: 0,
                timestamp: 0
            ))
        }

        // Tessellate the circle
        let handleStyle = InkStyle(
            red: handleColor.0,
            green: handleColor.1,
            blue: handleColor.2,
            alpha: 1.0,
            pressure: PressureCurve(minWidth: 3.0, maxWidth: 3.0, exponent: 1.0, tiltBroadening: 0)
        )
        let resampled = StrokeSmoother.resample(circlePoints)
        return Tessellator.tessellate(resampled, style: handleStyle)
    }

    /// Generate vertices for a connection arrow from one node to another.
    private func connectionArrowVertices(_ connection: Connection) -> [InkVertex] {
        // Find source and target nodes
        guard let sourceNode = nodes.first(where: { $0.id == connection.from }),
              let targetNode = nodes.first(where: { $0.id == connection.to }) else {
            return []
        }

        let start = sourceNode.bounds.center
        let end = targetNode.bounds.center

        // Calculate direction vector
        let direction = end - start
        guard let normalized = direction.normalized else { return [] }

        // Arrow styling - highlight selected connections
        let isSelected = (connection.id == selectedConnectionId)
        let arrowColor = isSelected ? (0.9, 0.6, 0.2) : (0.5, 0.5, 0.5)  // Orange for selected, gray for normal
        let shaftWidth = isSelected ? 4.0 : 2.0
        let arrowHeadLength = 20.0
        let arrowHeadWidth = isSelected ? 16.0 : 12.0

        // Calculate arrow head position (stop before reaching center of target node)
        let arrowHeadBase = end - normalized * arrowHeadLength

        // Create shaft as a line from start to arrow head base
        let shaftPoints = [
            InkPoint(position: start, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: 0),
            InkPoint(position: arrowHeadBase, force: 0.5, altitude: .pi / 2, azimuth: 0, timestamp: 0)
        ]

        let shaftStyle = InkStyle(
            red: arrowColor.0,
            green: arrowColor.1,
            blue: arrowColor.2,
            alpha: 1.0,
            pressure: PressureCurve(minWidth: shaftWidth, maxWidth: shaftWidth, exponent: 1.0, tiltBroadening: 0)
        )

        var vertices = Tessellator.tessellate(StrokeSmoother.resample(shaftPoints), style: shaftStyle)

        // Create arrow head as a triangle
        let perpendicular = normalized.perpendicular
        let headLeft = arrowHeadBase + perpendicular * (arrowHeadWidth / 2)
        let headRight = arrowHeadBase - perpendicular * (arrowHeadWidth / 2)
        let headTip = end

        // Create triangle vertices manually
        let r = Float(arrowColor.0)
        let g = Float(arrowColor.1)
        let b = Float(arrowColor.2)
        vertices.append(InkVertex(x: Float(headLeft.x), y: Float(headLeft.y), r: r, g: g, b: b))
        vertices.append(InkVertex(x: Float(headRight.x), y: Float(headRight.y), r: r, g: g, b: b))
        vertices.append(InkVertex(x: Float(headTip.x), y: Float(headTip.y), r: r, g: g, b: b))

        return vertices
    }

    public func clear() {
        strokes.removeAll()
        nodes.removeAll()
        connections.removeAll()
        committedVertices.removeAll()
        renderer.setCommittedGeometry([])
        renderer.setLiveGeometry([])
        collector.reset()
        needsRedraw = true
    }

    public func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        // Rebuild from the surviving strokes
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a stroke received from a peer (for sync).
    public func addReceivedStroke(_ stroke: Stroke) {
        // Check for duplicates (can happen with multiple peer connections)
        guard !strokes.contains(where: { $0.id == stroke.id }) else {
            print("⚠️ addReceivedStroke: ignoring duplicate stroke \(stroke.id)")
            return
        }
        strokes.append(stroke)
        // Rebuild geometry to include the new stroke
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a stroke received from a peer (for sync).
    public func deleteReceivedStroke(id: UUID) {
        guard let index = strokes.firstIndex(where: { $0.id == id }) else {
            print("⚠️ deleteReceivedStroke: stroke \(id) not found in \(strokes.count) strokes")
            return
        }
        print("✅ deleteReceivedStroke: deleting stroke \(id) at index \(index)")
        strokes.remove(at: index)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a node received from a peer (for sync).
    public func addReceivedNode(_ node: Node) {
        // Check if node already exists (avoid duplicates)
        guard !nodes.contains(where: { $0.id == node.id }) else { return }
        nodes.append(node)

        // Create Connection objects from the node's connections array (outgoing connections)
        print("📥 addReceivedNode(\(node.id)) with node.connections=\(node.connections)")
        for targetId in node.connections {
            // Only create if both nodes exist and connection doesn't already exist
            if nodes.contains(where: { $0.id == targetId }) &&
               !connections.contains(where: { $0.from == node.id && $0.to == targetId }) {
                let connection = Connection(from: node.id, to: targetId)
                connections.append(connection)
                print("🔗 Created outgoing connection: \(node.id) → \(targetId)")
            } else if !nodes.contains(where: { $0.id == targetId }) {
                print("⚠️ Target node \(targetId) not found yet")
            }
        }

        // Also check if any OTHER nodes point to this new node (incoming connections)
        for otherNode in nodes where otherNode.id != node.id {
            if otherNode.connections.contains(node.id) {
                // This node points to us - create the connection if it doesn't exist
                if !connections.contains(where: { $0.from == otherNode.id && $0.to == node.id }) {
                    let connection = Connection(from: otherNode.id, to: node.id)
                    connections.append(connection)
                    print("🔗 Created incoming connection: \(otherNode.id) → \(node.id)")
                }
            }
        }
        print("📊 After addReceivedNode(\(node.id)): total connections = \(connections.count)")

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Update a node received from a peer (for sync).
    public func updateReceivedNode(_ node: Node) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node

        // Rebuild Connection objects from the node's updated connections array
        // First remove old connections FROM this node
        connections.removeAll { $0.from == node.id }

        // Then create new connections based on updated connections array
        for targetId in node.connections {
            // Create connection if both source and target nodes exist
            if nodes.contains(where: { $0.id == targetId }) {
                let connection = Connection(from: node.id, to: targetId)
                connections.append(connection)
            }
            // Note: If target doesn't exist yet, the connection will be created
            // when that node is received and addReceivedNode checks for incoming connections
        }

        // Also check if any OTHER nodes point to this node, and create those connections
        for otherNode in nodes where otherNode.id != node.id {
            if otherNode.connections.contains(node.id) {
                // This node points to us - create the connection if it doesn't exist
                if !connections.contains(where: { $0.from == otherNode.id && $0.to == node.id }) {
                    let connection = Connection(from: otherNode.id, to: node.id)
                    connections.append(connection)
                }
            }
        }

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a node received from a peer (for sync).
    public func deleteReceivedNode(id: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }

        // Clean up all connections to/from this node (without syncing since we're receiving)
        let connectionsToRemove = connections.filter { $0.from == id || $0.to == id }
        connections.removeAll { $0.from == id || $0.to == id }

        // Remove from all nodes' connection lists
        for i in nodes.indices {
            nodes[i].connections.removeAll { $0 == id }
        }

        nodes.remove(at: index)
        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a connection received from a peer (for sync).
    public func addReceivedConnection(_ connection: Connection) {
        // Don't add if it already exists
        guard !connections.contains(where: { $0.id == connection.id }) else { return }

        // Verify both nodes exist
        guard nodes.contains(where: { $0.id == connection.from }),
              nodes.contains(where: { $0.id == connection.to }) else {
            return
        }

        connections.append(connection)

        // Update source node's connections array
        if let index = nodes.firstIndex(where: { $0.id == connection.from }) {
            if !nodes[index].connections.contains(connection.to) {
                nodes[index].connections.append(connection.to)
            }
        }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a connection received from a peer (for sync).
    public func deleteReceivedConnection(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections[index]
        connections.remove(at: index)

        // Update source node's connections array
        if let nodeIndex = nodes.firstIndex(where: { $0.id == connection.from }) {
            nodes[nodeIndex].connections.removeAll { $0 == connection.to }
        }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    // MARK: - Connection Management

    /// Add a connection from one node to another. Returns true if added, false if rejected.
    /// Rejects self-loops (from == to) and duplicate connections.
    @discardableResult
    public func addConnection(from sourceId: UUID, to targetId: UUID) -> Bool {
        // Reject self-loops
        guard sourceId != targetId else { return false }

        // Reject if connection already exists
        if connections.contains(where: { $0.from == sourceId && $0.to == targetId }) {
            return false
        }

        // Verify both nodes exist
        guard nodes.contains(where: { $0.id == sourceId }),
              nodes.contains(where: { $0.id == targetId }) else {
            return false
        }

        // Create connection
        let connection = Connection(from: sourceId, to: targetId)
        connections.append(connection)

        // Update source node's connections array
        if let index = nodes.firstIndex(where: { $0.id == sourceId }) {
            if !nodes[index].connections.contains(targetId) {
                nodes[index].connections.append(targetId)
            }
        }

        // Notify sync about connection creation
        onConnectionCreated?(connection)

        return true
    }

    /// Remove a connection by its ID.
    public func removeConnection(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections[index]
        connections.remove(at: index)

        // Update source node's connections array
        if let nodeIndex = nodes.firstIndex(where: { $0.id == connection.from }) {
            nodes[nodeIndex].connections.removeAll { $0 == connection.to }
        }

        // Clear selection if this connection was selected
        if selectedConnectionId == id {
            selectedConnectionId = nil
        }

        // Notify sync about connection deletion
        onConnectionDeleted?(id)

        // Rebuild geometry to remove the arrow
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Remove all connections to/from a specific node.
    /// Called when deleting a node - the node deletion itself will be synced,
    /// and the peer will clean up connections when it receives the node deletion.
    public func removeAllConnections(for nodeId: UUID) {
        // Remove from connections array
        connections.removeAll { $0.from == nodeId || $0.to == nodeId }

        // Remove from all nodes' connection lists
        for i in nodes.indices {
            nodes[i].connections.removeAll { $0 == nodeId }
        }
    }

    /// Get all connections where this node is the source.
    public func outgoingConnections(from nodeId: UUID) -> [Connection] {
        return connections.filter { $0.from == nodeId }
    }

    /// Get all connections where this node is the target.
    public func incomingConnections(to nodeId: UUID) -> [Connection] {
        return connections.filter { $0.to == nodeId }
    }

    // MARK: - Frame

    @objc private func step(_ link: CADisplayLink) {
        if lastFrameTimestamp > 0 {
            let delta = link.timestamp - lastFrameTimestamp
            if delta > 0 {
                let instant = 1.0 / delta
                smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
            }
        }
        lastFrameTimestamp = link.timestamp

        // Build live geometry: current stroke OR lasso path
        var liveVertices: [InkVertex] = []

        if collector.isDrawing && drawMode == .draw {
            let points = collector.renderPoints
            // Convert live points to world space before tessellating
            let worldPoints = toWorldSpace(points)
            let resampled = StrokeSmoother.resample(worldPoints)
            liveVertices = Tessellator.tessellate(resampled, style: style)
            needsRedraw = true
        } else if !lassoPath.isEmpty && drawMode == .lasso {
            // Render lasso path as a line
            liveVertices = lassoPathVertices()
            needsRedraw = true
        }

        renderer.setLiveGeometry(liveVertices)

        guard needsRedraw else { return }
        needsRedraw = false

        renderer.draw(in: metalLayer, alpha: style.alpha, cameraOffset: camera.offset, cameraZoom: camera.zoom)

        onStatsUpdate?(HUDStats(
            strokeCount: strokes.count,
            liveSamples: collector.committed.count,
            predictedSamples: collector.predicted.count,
            estimateCorrections: collector.estimateCorrections,
            liveVertices: renderer.stats.liveVertexCount,
            committedVertices: renderer.stats.committedVertexCount,
            cpuFrameMilliseconds: renderer.stats.lastFrameMilliseconds,
            displayFPS: smoothedFPS
        ))
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // Don't interfere with resize - finger touches handle that
        if activeResizeHandle {
            gesture.state = .cancelled
            return
        }

        switch gesture.state {
        case .began:
            // Check if we're starting on a node
            let location = gesture.location(in: self)
            let viewPoint = Vec2(Double(location.x), Double(location.y))

            // Don't start pan if we're on a resize handle
            if let selectedId = selectedNodeId,
               isNearResizeHandle(viewPoint: viewPoint, for: selectedId) {
                gesture.state = .cancelled
                return
            }

            if let nodeIndex = nodeAt(viewPoint: viewPoint) {
                // Start dragging this node
                draggingNodeIndex = nodeIndex
                let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
                let worldPoint = camera.viewToWorld(viewPoint, viewSize: viewSize)
                dragOffset = worldPoint - nodes[nodeIndex].bounds.center
            }

        case .changed:
            if let nodeIndex = draggingNodeIndex {
                // Drag the node
                let location = gesture.location(in: self)
                let viewPoint = Vec2(Double(location.x), Double(location.y))
                let viewSize = Vec2(Double(bounds.width), Double(bounds.height))
                let worldPoint = camera.viewToWorld(viewPoint, viewSize: viewSize)

                // Calculate new center accounting for drag offset
                let newCenter = worldPoint - dragOffset
                let currentCenter = nodes[nodeIndex].bounds.center
                let delta = newCenter - currentCenter

                // Move the node by updating its bounds
                nodes[nodeIndex].bounds.x += delta.x
                nodes[nodeIndex].bounds.y += delta.y

                // Also move all strokes inside the node
                for i in 0..<nodes[nodeIndex].strokes.count {
                    for j in 0..<nodes[nodeIndex].strokes[i].points.count {
                        nodes[nodeIndex].strokes[i].points[j].position =
                            nodes[nodeIndex].strokes[i].points[j].position + delta
                    }
                }

                rebuildCommittedGeometry()
                needsRedraw = true
            } else {
                // Pan the canvas
                let translation = gesture.translation(in: self)
                camera.pan(by: Vec2(Double(translation.x), Double(translation.y)))
                gesture.setTranslation(.zero, in: self)
                needsRedraw = true
            }

        case .ended, .cancelled:
            // Notify sync if a node was being dragged
            if let nodeIndex = draggingNodeIndex {
                onNodeUpdated?(nodes[nodeIndex])
            }
            draggingNodeIndex = nil

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: self)
        let anchor = Vec2(Double(location.x), Double(location.y))
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))

        camera.zoom(by: Float(gesture.scale), anchor: anchor, viewSize: viewSize)
        gesture.scale = 1.0
        needsRedraw = true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let viewPoint = Vec2(Double(location.x), Double(location.y))

        // Check for connection tap first (connections are thinner, so prioritize them)
        if let connection = connectionAt(viewPoint: viewPoint) {
            // Select this connection
            selectedConnectionId = connection.id
            selectedNodeId = nil  // Deselect any selected node
            onConnectionSelected?(connection.id)
            onNodeSelected?(nil)
            rebuildCommittedGeometry()
            needsRedraw = true
        } else if let nodeIndex = nodeAt(viewPoint: viewPoint) {
            // Select this node
            let nodeId = nodes[nodeIndex].id
            selectedNodeId = nodeId
            selectedConnectionId = nil  // Deselect any selected connection
            onNodeSelected?(nodeId)
            onConnectionSelected?(nil)
            rebuildCommittedGeometry()
            needsRedraw = true
        } else {
            // Deselect if tapping empty space
            if selectedNodeId != nil || selectedConnectionId != nil {
                selectedNodeId = nil
                selectedConnectionId = nil
                onNodeSelected?(nil)
                onConnectionSelected?(nil)
                rebuildCommittedGeometry()
                needsRedraw = true
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MetalInkView: UIGestureRecognizerDelegate {
    /// Allow pan and pinch to work simultaneously with each other.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Pan and pinch can work together
        return true
    }

    /// Prevent gestures from starting while actively drawing with the Pencil.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't allow pan/zoom to start while drawing
        if collector.isDrawing {
            return false
        }

        // Don't allow pan to start if we're on a resize handle
        if gestureRecognizer is UIPanGestureRecognizer {
            let location = gestureRecognizer.location(in: self)
            let viewPoint = Vec2(Double(location.x), Double(location.y))

            // Check if we're on a resize handle
            if let selectedId = selectedNodeId,
               isNearResizeHandle(viewPoint: viewPoint, for: selectedId) {
                return false
            }
        }

        return true
    }

    /// Only allow finger touches for gestures, not the Pencil.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Pencil should not trigger pan/zoom gestures
        if touch.type == .pencil {
            return false
        }

        // For tap gestures, always allow them (they handle selection/deselection)
        if gestureRecognizer is UITapGestureRecognizer {
            return true
        }

        // For pan gestures on resize handle, don't allow the gesture
        // (touch events will handle it directly)
        if gestureRecognizer is UIPanGestureRecognizer {
            let location = touch.location(in: self)
            let viewPoint = Vec2(Double(location.x), Double(location.y))

            if let selectedId = selectedNodeId,
               isNearResizeHandle(viewPoint: viewPoint, for: selectedId) {
                return false
            }
        }

        return true
    }
}
#endif
