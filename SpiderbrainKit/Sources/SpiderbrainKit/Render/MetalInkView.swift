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

    /// Owns the canvas and every operation on it. The view holds no canvas state
    /// of its own; the properties below are read-only views of the controller's.
    private let canvas = CanvasController()

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
            case .canvasCleared:
                onCanvasCleared?()
            }
        }
    }

    /// Read-only views. Mutate by calling an operation on the controller.
    private var strokes: [Stroke] { canvas.strokes }
    private var nodes: [Node] { canvas.nodes }
    private var connections: [Connection] { canvas.connections }

    private var committedVertices: [InkVertex] = []
    private var needsRedraw = true

    /// Camera for pan and zoom. M2: world-space coordinates.
    public var camera = Camera()

    /// Public accessor for the nodes list (read-only for UI display).
    public var allNodes: [Node] { nodes }

    /// Public accessor for connections list (read-only for UI display).
    public var allConnections: [Connection] { connections }

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

    /// Callback when the canvas is cleared (for sync).
    public var onCanvasCleared: (() -> Void)?

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

        collector.begin(touch, in: self)
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

        collector.update(with: touch, event: event, in: self)
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

        let points = collector.finish(touch, in: self)
        commit(points)
        needsRedraw = true
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        collector.reset()
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
        if let firstPoint = worldPoints.first?.position, let lastPoint = worldPoints.last?.position {
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
        broadcast(canvas.addStroke(stroke))

        // Append this stroke's geometry to the committed buffer rather than
        // re-tessellating every stroke. M2 replaces this with tile rasterisation.
        let resampled = StrokeSmoother.resample(worldPoints)
        committedVertices.append(contentsOf: Tessellator.tessellate(resampled, style: stroke.style))
        renderer.setCommittedGeometry(committedVertices)
        renderer.setLiveGeometry([])

        // M2 prototype: Auto-detect closed shapes for node creation
        if isClosedShape(stroke) {
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
        ShapeDetection.isClosedShape(stroke, among: strokes)
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
        let effects = canvas.convertStrokeToNode(strokeId: strokeId)
        guard !effects.isEmpty else { return }

        broadcast(effects)
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    public func convertStrokeToNodeWithAbsorb(strokeId: UUID) {
        let effects = canvas.convertStrokeToNodeWithAbsorb(strokeId: strokeId)
        guard !effects.isEmpty else { return }

        broadcast(effects)
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    /// The current camera paired with the view's size.
    private var viewTransform: ViewTransform {
        ViewTransform(camera: camera, viewSize: Vec2(Double(bounds.width), Double(bounds.height)))
    }

    /// Index of the topmost node at a view point.
    ///
    /// Still index-based because the drag machinery tracks `draggingNodeIndex`;
    /// the hit test itself lives in `CanvasHitTesting`.
    private func nodeAt(viewPoint: Vec2) -> Int? {
        guard let hit = CanvasHitTesting.node(at: viewPoint, in: nodes, transform: viewTransform)
        else { return nil }
        return nodes.firstIndex(where: { $0.id == hit.id })
    }

    /// Find a connection at the given view point (within tap distance).
    private func connectionAt(viewPoint: Vec2) -> Connection? {
        CanvasHitTesting.connection(
            at: viewPoint,
            in: connections,
            nodes: nodes,
            transform: viewTransform
        )
    }

    /// Detect and absorb strokes inside a specific node (one-time action).
    public func detectStrokesInNode(nodeId: UUID) {
        let effects = canvas.detectStrokesInNode(nodeId: nodeId)

        if !effects.isEmpty {
            broadcast(effects)
            rebuildCommittedGeometry()
            needsRedraw = true
        }

        // Always notify the UI, even when nothing moved.
        onNodesChanged?(nodes)
    }

    // MARK: - Text Recognition

    /// Recognize handwritten text in a specific node using Vision Framework.
    /// Updates the node's recognizedText property and notifies UI.
    public func recognizeTextInNode(nodeId: UUID) async {
        guard let node = canvas.node(withId: nodeId) else { return }

        // Recognition itself is a platform service, so it runs here rather than in
        // the controller; only the result crosses over.
        let result = await recognitionService.recognizeText(from: node)

        switch result {
        case .success(let text, let confidence, let source):
            let sourceData: RecognizedText.RecognitionSourceData
            switch source {
            case .vision(let conf):
                sourceData = .vision(confidence: conf)
            case .customModel(let conf):
                sourceData = .customModel(confidence: conf)
            case .correctionHistory(let conf):
                sourceData = .correctionHistory(matchConfidence: conf)
            }

            let recognized = RecognizedText(
                text: text,
                confidence: confidence,
                source: sourceData
            )
            broadcast(canvas.applyRecognizedText(recognized, toNodeId: nodeId))
            onNodesChanged?(nodes)

        case .failure(let error):
            print("❌ Text recognition failed for node \(nodeId): \(error)")
        }
    }

    /// Store text typed into a node.
    ///
    /// - Parameter fittingBounds: a box big enough to render the text, measured by
    ///   the caller. The node grows to fit but never shrinks.
    public func setNodeText(_ text: String, onNodeId nodeId: UUID, fittingBounds: Rect) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effects = canvas.setText(
            trimmed.isEmpty ? nil : trimmed,
            onNodeId: nodeId,
            fittingBounds: fittingBounds
        )
        guard !effects.isEmpty else { return }

        broadcast(effects)
        rebuildCommittedGeometry()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    /// Delete a node by its ID, returning its strokes to the canvas.
    public func deleteNode(id nodeId: UUID) {
        // The executor returns the strokes and drops the node's edges in one step.
        let effects = canvas.deleteNode(id: nodeId)
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
        guard let node = canvas.node(withId: nodeId) else { return nil }
        return CanvasHitTesting.resizeHandlePosition(for: node, transform: viewTransform)
    }

    /// Check if a point in view space is near the bottom-right resize handle.
    private func isNearResizeHandle(viewPoint: Vec2, for nodeId: UUID) -> Bool {
        guard let node = canvas.node(withId: nodeId) else { return false }
        return CanvasHitTesting.isNearResizeHandle(
            viewPoint: viewPoint,
            node: node,
            transform: viewTransform
        )
    }

    /// Resize a node by dragging the bottom-right handle to endPoint (view space).
    /// Scales proportionally maintaining aspect ratio - handle moves diagonally (like GoodNotes).
    private func resizeNode(id nodeId: UUID, endPoint: Vec2) {
        // Scale against the bounds captured when the drag began, so repeated
        // frames measure from a fixed origin rather than compounding.
        guard let startBounds = resizeStartBounds,
              let startStrokes = resizeStartStrokes else { return }

        let effects = canvas.resizeNode(
            id: nodeId,
            to: endPoint,
            startBounds: startBounds,
            startStrokes: startStrokes,
            transform: viewTransform
        )
        guard !effects.isEmpty else { return }

        // Not broadcast per frame: one update goes out on release.
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    private func pointInPolygon(_ point: Vec2, polygon: [Vec2]) -> Bool {
        return GeometryManager.pointInPolygon(point, polygon: polygon)
    }

    /// Rebuild committed geometry from the current canvas contents.
    private func rebuildCommittedGeometry() {
        committedVertices = CanvasVertexBuilder.committedGeometry(
            strokes: strokes,
            nodes: nodes,
            connections: connections,
            highlight: currentHighlight,
            transform: viewTransform
        )
        renderer.setCommittedGeometry(committedVertices)
    }

    /// What is currently selected, which changes how things are drawn.
    private var currentHighlight: CanvasVertexBuilder.Highlight {
        CanvasVertexBuilder.Highlight(
            selectedNodeId: selectedNodeId,
            selectedConnectionId: selectedConnectionId
        )
    }

    public func clear() {
        // Announced as one `canvasCleared` message rather than a deletion per item,
        // so a peer cannot end up half-cleared if the connection drops midway.
        broadcast(canvas.clear())
        resetRenderState()
    }

    /// Wipe the canvas because a peer did. Not re-announced.
    public func clearReceivedCanvas() {
        _ = canvas.applyReceivedClear()
        resetRenderState()
    }

    private func resetRenderState() {
        committedVertices.removeAll()
        renderer.setCommittedGeometry([])
        renderer.setLiveGeometry([])
        collector.reset()
        needsRedraw = true
        onNodesChanged?(nodes)
    }

    public func undoLastStroke() {
        let effects = canvas.undoLastStroke()

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
        let effects = canvas.applyReceivedStroke(stroke)
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
        let effects = canvas.applyReceivedStrokeDeletion(id: id)
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
        let effects = canvas.applyReceivedNode(node)
        guard !effects.isEmpty else { return }

        onNodesChanged?(nodes)
        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Update a node received from a peer (for sync).
    public func updateReceivedNode(_ node: Node) {
        let effects = canvas.applyReceivedNodeUpdate(node)
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
        let effects = canvas.applyReceivedNodeDeletion(id: id)
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
        let effects = canvas.applyReceivedConnection(connection)
        guard !effects.isEmpty else { return }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    /// Delete a connection received from a peer (for sync).
    public func deleteReceivedConnection(id: UUID) {
        let effects = canvas.applyReceivedConnectionDeletion(id: id)
        guard !effects.isEmpty else { return }

        rebuildCommittedGeometry()
        needsRedraw = true
    }

    // MARK: - Connection Management

    /// Add a connection from one node to another. Returns true if added, false if rejected.
    /// Rejects self-loops, duplicates, and edges to nodes that don't exist.
    @discardableResult
    public func addConnection(from sourceId: UUID, to targetId: UUID) -> Bool {
        let effects = canvas.connect(from: sourceId, to: targetId)
        guard !effects.isEmpty else { return false }

        broadcast(effects)

        return true
    }

    /// Remove a connection by its ID.
    public func removeConnection(id: UUID) {
        let effects = canvas.disconnect(id: id)
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

        // Build live geometry for the stroke in progress
        var liveVertices: [InkVertex] = []

        if collector.isDrawing {
            let points = collector.renderPoints
            // Convert live points to world space before tessellating
            let worldPoints = toWorldSpace(points)
            let resampled = StrokeSmoother.resample(worldPoints)
            liveVertices = Tessellator.tessellate(resampled, style: style)
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

                // Move by the delta from where the node sits now.
                // Not synced per frame: one update goes out on release.
                let newCenter = worldPoint - dragOffset
                let delta = newCenter - nodes[nodeIndex].bounds.center
                _ = canvas.moveNode(id: nodes[nodeIndex].id, by: delta)

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
