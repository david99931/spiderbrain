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

    /// Owns the canvas — strokes, nodes and connections. Every mutation goes
    /// through this; the properties below are read-only views of its contents.
    private let canvas = CanvasCommandExecutor()

    /// Announce a set of effects to peers in an order they can apply.
    ///
    /// Ordering is decided by `CanvasSyncPlanner`, not here: a peer rejects an edge
    /// whose endpoints it has not seen and never retries, so nodes must precede the
    /// edges naming them. Routing every broadcast through the planner makes that
    /// structural rather than something each call site has to remember.
    private func broadcast(_ effects: [CanvasEffect]) {
        for intent in CanvasSyncPlanner.plan(for: effects) {
            switch intent {
            case .strokeAdded(let stroke):
                onStrokeCommitted?(stroke)
            case .strokeDeleted(let id):
                onStrokeDeleted?(id)
            case .nodeCreated(let node):
                onNodeCreated?(node)
            case .nodeCreatedConsumingStrokes(let node, let deletedStrokeIds):
                onNodeCreatedWithStrokeDeletions?(node, deletedStrokeIds)
            case .nodeUpdated(let node):
                onNodeUpdated?(node)
            case .nodeDeleted(let id):
                onNodeDeleted?(id)
            case .connectionCreated(let connection):
                onConnectionCreated?(connection)
            case .connectionDeleted(let id):
                onConnectionDeleted?(id)
            }
        }
    }

    /// Read-only views. Mutate via `canvas.execute`.
    private var strokes: [Stroke] { canvas.strokes }
    private var nodes: [Node] { canvas.nodes }
    private var connections: [Connection] { canvas.connections }

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
    /// Passes the id of the closed-shape stroke. Identity rather than position,
    /// because the receiver queues this across user interaction and the stroke
    /// array can change in the meantime.
    public var onClosedShapeDetected: ((UUID) -> Void)?

    /// M2 prototype: Callback when a closed shape contains nodes (for absorb choice).
    /// Passes the closed-shape stroke id and the ids of the nodes it encloses.
    public var onClosedShapeWithNodes: ((UUID, [UUID]) -> Void)?

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

    /// Whether a touch should draw ink.
    ///
    /// Apple Pencil on iPad, and trackpad or mouse when the app runs on a Mac.
    /// A pointer reports no force, so `StrokeInputCollector` gives it a fixed
    /// mid-pressure and strokes come out at an even width.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        touch.type == .pencil || touch.type == .indirectPointer
    }

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

        guard isDrawingTouch(touch) else { return }

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

        guard isDrawingTouch(touch) else { return }

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

        guard isDrawingTouch(touch) else { return }

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
        broadcast(canvas.execute(.addStroke(stroke), origin: .local))

        // Append this stroke's geometry to the committed buffer rather than
        // re-tessellating every stroke. M2 replaces this with tile rasterisation.
        let resampled = StrokeSmoother.resample(worldPoints)
        committedVertices.append(contentsOf: Tessellator.tessellate(resampled, style: stroke.style))
        renderer.setCommittedGeometry(committedVertices)
        renderer.setLiveGeometry([])

        // M2 prototype: Auto-detect closed shapes for node creation
        if drawMode == .draw && isClosedShape(stroke) {
            // Check if there are nodes inside this closed shape
            let boundaryPolygon = stroke.points.map { $0.position }
            let containedNodeIds = nodes
                .filter { pointInPolygon($0.bounds.center, polygon: boundaryPolygon) }
                .map(\.id)

            // Call appropriate callback based on whether nodes are inside
            if !containedNodeIds.isEmpty {
                onClosedShapeWithNodes?(stroke.id, containedNodeIds)
            } else {
                onClosedShapeDetected?(stroke.id)
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

    /// Convert the stroke with the given id into a node.
    /// The stroke is treated as a boundary shape - any strokes inside it are included in the node.
    /// The boundary stroke itself is replaced with a clean rectangle outline.
    /// If there are nodes inside, creates an empty node (no auto-absorb of nodes).
    ///
    /// Takes an id rather than an index because callers queue this across user
    /// interaction, during which the stroke array can change.
    public func convertStrokeToNode(strokeId: UUID) {
        guard let index = strokes.firstIndex(where: { $0.id == strokeId }) else {
            print("⚠️ convertStrokeToNode: stroke \(strokeId) no longer exists")
            return
        }

        let boundaryStroke = strokes[index]

        guard isClosedShape(boundaryStroke) else {
            print("⚠️ convertStrokeToNode: stroke \(strokeId) is not a closed shape")
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

        // Collect stroke IDs BEFORE removing them
        var deletedStrokeIds: [UUID] = []
        for i in indicesToRemove {
            if i >= 0 && i < strokes.count {
                deletedStrokeIds.append(strokes[i].id)
            }
        }

        // One command: the node appears and its strokes leave the canvas together.
        let effects = canvas.execute(
            .createNode(node, consumingStrokes: deletedStrokeIds),
            origin: .local
        )

        broadcast(effects)

        // Rebuild geometry
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    /// Convert a stroke to a node and absorb all nodes inside it.
    ///
    /// Takes an id rather than an index for the same reason as `convertStrokeToNode`.
    public func convertStrokeToNodeWithAbsorb(strokeId: UUID) {
        guard let index = strokes.firstIndex(where: { $0.id == strokeId }) else {
            print("⚠️ convertStrokeToNodeWithAbsorb: stroke \(strokeId) no longer exists")
            return
        }

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
        guard let bounds = Node.computeBounds(allStrokes.isEmpty ? [boundaryStroke] : allStrokes) else {
            return
        }
        let mergedNode = Node(strokes: allStrokes, bounds: bounds, boundaryStroke: boundaryStroke)

        let deletedStrokeIds = indicesToRemove
            .filter { $0 >= 0 && $0 < strokes.count }
            .map { strokes[$0].id }

        // One atomic command. The executor deletes the strokes, removes the absorbed
        // nodes, adds the merged node, and re-points the absorbed nodes' external
        // edges at it — so a peer never observes the canvas mid-merge.
        let effects = canvas.execute(
            .mergeNodes(
                absorbing: Array(enclosedNodeIds),
                into: mergedNode,
                consumingStrokes: deletedStrokeIds
            ),
            origin: .local
        )

        broadcast(effects)

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
            // Don't clear recognized text - let user re-recognize manually to add new words
            // This way "david" stays, and clicking recognize again will find "david hello"
            // Don't recalculate bounds - keep the original circle size
            var absorbing = nodes[nodeIndex]
            absorbing.strokes.append(contentsOf: strokesToAbsorb)
            var effects = canvas.execute(.updateNode(absorbing), origin: .local)
            effects += canvas.execute(
                .deleteStrokes(ids: strokesToAbsorb.map(\.id)),
                origin: .local
            )
            broadcast(effects)

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
            guard var node = canvas.node(withId: nodeId) else { return }
            node.recognizedText = RecognizedText(
                text: text,
                confidence: confidence,
                source: sourceData
            )
            canvas.execute(.updateNode(node), origin: .local)

            // Notify UI
            onNodesChanged?(nodes)

        case .failure(let error):
            print("❌ Text recognition failed for node \(nodeId): \(error)")
        }
    }

    /// Delete a node by its ID, returning its strokes to the canvas.
    public func deleteNode(id nodeId: UUID) {
        // The executor returns the strokes and drops the node's edges in one step.
        let effects = canvas.execute(.deleteNode(id: nodeId, returningStrokes: true), origin: .local)
        guard !effects.isEmpty else { return }

        broadcast(effects)

        // Rebuild geometry
        rebuildCommittedGeometry()
        needsRedraw = true
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
        var resized = nodes[nodeIndex]
        resized.strokes = scaledStrokes
        resized.bounds = newBounds
        canvas.execute(.updateNode(resized), origin: .local)

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
            canvas.execute(
                .createNode(node, consumingStrokes: selectedStrokes.map(\.id)),
                origin: .local
            )

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

        // Build the absorbed node: existing strokes plus the newly absorbed ones.
        var absorbedNode = nodes[nodeIndex]
        absorbedNode.strokes.append(contentsOf: strokesToAbsorb)
        if let newBounds = Node.computeBounds(absorbedNode.strokes) {
            absorbedNode.bounds = newBounds
        }

        let deletedNodeIds = nodesToRemove.map { nodes[$0].id }

        var effects: [CanvasEffect] = []
        if deletedNodeIds.isEmpty {
            effects += canvas.execute(.updateNode(absorbedNode), origin: .local)
        } else {
            // Nodes are being swallowed, so this is a merge: the executor removes
            // them and re-points their external edges at the surviving node.
            effects += canvas.execute(
                .mergeNodes(absorbing: deletedNodeIds + [absorbedNode.id],
                            into: absorbedNode,
                            consumingStrokes: []),
                origin: .local
            )
        }

        // Remove these strokes from the main canvas
        let absorbedStrokeIds = strokes
            .filter { strokeIdentifiers.contains(StrokeIdentifier(stroke: $0)) }
            .map(\.id)
        effects += canvas.execute(.deleteStrokes(ids: absorbedStrokeIds), origin: .local)

        broadcast(effects)

        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)  // Notify UI to refresh
    }

    /// Create a new node from strokes (separate operation).
    public func separateIntoNewNode(strokes strokesToSeparate: [Stroke]) {
        guard !strokesToSeparate.isEmpty else { return }

        if let bounds = Node.computeBounds(strokesToSeparate) {
            let node = Node(strokes: strokesToSeparate, bounds: bounds)

            // Work out which canvas strokes the new node swallows.
            var separatedStrokeIds: [UUID] = []
            for stroke in strokes {
                let isSeparated = strokesToSeparate.contains { separatedStroke in
                    separatedStroke.points.count == stroke.points.count &&
                    separatedStroke.points.first?.position == stroke.points.first?.position
                }
                if isSeparated {
                    separatedStrokeIds.append(stroke.id)
                }
            }
            let effects = canvas.execute(
                .createNode(node, consumingStrokes: separatedStrokeIds),
                origin: .local
            )
            broadcast(effects)

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
        // Local-only. Clearing wipes strokes, nodes and connections, and the wire
        // protocol has no atomic "clear canvas" message — syncing it as hundreds of
        // individual deletions would be non-atomic and could leave a peer showing a
        // half-cleared canvas. Revisit once nodes and connections have executors.
        canvas.execute(.clearCanvas, origin: .local)
        committedVertices.removeAll()
        renderer.setCommittedGeometry([])
        renderer.setLiveGeometry([])
        collector.reset()
        needsRedraw = true
    }

    public func undoLastStroke() {
        let effects = canvas.execute(.removeLastStroke, origin: .local)

        // The executor reports only strokes that were really there, so an undo on
        // an empty canvas broadcasts nothing.
        broadcast(effects)

        // Rebuild from the surviving strokes
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a stroke received from a peer (for sync).
    public func addReceivedStroke(_ stroke: Stroke) {
        // The executor is idempotent by stroke id, so duplicates arriving over
        // multiple peer connections are dropped here rather than at each call site.
        let effects = canvas.execute(.addStroke(stroke), origin: .remote)
        guard !effects.isEmpty else {
            print("⚠️ addReceivedStroke: ignoring duplicate stroke \(stroke.id)")
            return
        }
        // Rebuild geometry to include the new stroke
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a stroke received from a peer (for sync).
    public func deleteReceivedStroke(id: UUID) {
        let effects = canvas.execute(.deleteStrokes(ids: [id]), origin: .remote)
        guard !effects.isEmpty else {
            print("⚠️ deleteReceivedStroke: stroke \(id) not found in \(strokes.count) strokes")
            return
        }
        print("✅ deleteReceivedStroke: deleted stroke \(id)")
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a node received from a peer (for sync).
    ///
    /// Edges arrive as their own messages rather than being reconstructed from the
    /// node, so there is nothing to reconcile here.
    public func addReceivedNode(_ node: Node) {
        let effects = canvas.execute(.createNode(node, consumingStrokes: []), origin: .remote)
        guard !effects.isEmpty else { return }

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Update a node received from a peer (for sync).
    public func updateReceivedNode(_ node: Node) {
        let effects = canvas.execute(.updateNode(node), origin: .remote)
        guard !effects.isEmpty else { return }

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a node received from a peer (for sync).
    ///
    /// The executor drops any edges touching the node, so a peer deleting a node
    /// cleans up its arrows without a separate message.
    public func deleteReceivedNode(id: UUID) {
        let effects = canvas.execute(.deleteNode(id: id, returningStrokes: false), origin: .remote)
        guard !effects.isEmpty else { return }

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Add a connection received from a peer (for sync).
    ///
    /// Dropped if either endpoint is missing, since the arrow would have nothing to
    /// draw between. Nothing retries a dropped edge, so senders must announce a node
    /// before any edge that points at it.
    public func addReceivedConnection(_ connection: Connection) {
        let effects = canvas.execute(
            .connect(from: connection.from, to: connection.to),
            origin: .remote
        )
        guard !effects.isEmpty else { return }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a connection received from a peer (for sync).
    public func deleteReceivedConnection(id: UUID) {
        let effects = canvas.execute(.disconnect(id: id), origin: .remote)
        guard !effects.isEmpty else { return }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    // MARK: - Connection Management

    /// Add a connection from one node to another. Returns true if added, false if rejected.
    /// Rejects self-loops, duplicates, and edges to nodes that don't exist.
    @discardableResult
    public func addConnection(from sourceId: UUID, to targetId: UUID) -> Bool {
        let effects = canvas.execute(.connect(from: sourceId, to: targetId), origin: .local)
        guard !effects.isEmpty else { return false }

        broadcast(effects)

        return true
    }

    /// Remove a connection by its ID.
    public func removeConnection(id: UUID) {
        let effects = canvas.execute(.disconnect(id: id), origin: .local)
        guard !effects.isEmpty else { return }

        // Clear selection if this connection was selected
        if selectedConnectionId == id {
            selectedConnectionId = nil
        }

        broadcast(effects)

        // Rebuild geometry to remove the arrow
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Get all connections where this node is the source.
    public func outgoingConnections(from nodeId: UUID) -> [Connection] {
        return canvas.outgoingConnections(from: nodeId)
    }

    /// Get all connections where this node is the target.
    public func incomingConnections(to nodeId: UUID) -> [Connection] {
        return canvas.incomingConnections(to: nodeId)
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
                var dragged = nodes[nodeIndex]
                let delta = newCenter - dragged.bounds.center

                // Move the node and the strokes inside it, then write it back.
                // Not synced per frame: one update goes out on release.
                dragged.bounds.x += delta.x
                dragged.bounds.y += delta.y
                for i in dragged.strokes.indices {
                    for j in dragged.strokes[i].points.indices {
                        dragged.strokes[i].points[j].position =
                            dragged.strokes[i].points[j].position + delta
                    }
                }
                canvas.execute(.updateNode(dragged), origin: .local)

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
            // Announce the drag once, on release, rather than every frame.
            // Read back by id: the index may no longer point where it did.
            if let nodeIndex = draggingNodeIndex,
               nodeIndex < nodes.count,
               let moved = canvas.node(withId: nodes[nodeIndex].id) {
                onNodeUpdated?(moved)
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

    /// Only allow finger touches for gestures, not whatever is drawing.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A drawing touch must not also pan or zoom, or a mouse drag on the Mac
        // would draw and pan the camera at the same time.
        if isDrawingTouch(touch) {
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
