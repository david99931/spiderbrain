#if os(iOS)
import UIKit
import QuartzCore

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

    private var strokes: [Stroke] = []
    private var committedVertices: [InkVertex] = []
    private var needsRedraw = true

    /// Camera for pan and zoom. M2: world-space coordinates.
    public var camera = Camera()

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
        // Only accept Apple Pencil touches for drawing
        guard let touch = touches.first, touch.type == .pencil else { return }
        collector.begin(touch, in: self)
        needsRedraw = true
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only accept Apple Pencil touches for drawing
        guard let touch = touches.first, touch.type == .pencil else { return }
        collector.update(with: touch, event: event, in: self)
        needsRedraw = true
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only accept Apple Pencil touches for drawing
        guard let touch = touches.first, touch.type == .pencil else { return }
        let points = collector.finish(touch, in: self)
        commit(points)
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
        let stroke = Stroke(points: worldPoints, style: style)
        strokes.append(stroke)

        // Append this stroke's geometry to the committed buffer rather than
        // re-tessellating every stroke. M2 replaces this with tile rasterisation.
        let resampled = StrokeSmoother.resample(worldPoints)
        committedVertices.append(contentsOf: Tessellator.tessellate(resampled, style: stroke.style))
        renderer.setCommittedGeometry(committedVertices)
        renderer.setLiveGeometry([])

        collector.reset()
        needsRedraw = true
    }

    public func clear() {
        strokes.removeAll()
        committedVertices.removeAll()
        renderer.setCommittedGeometry([])
        renderer.setLiveGeometry([])
        collector.reset()
        needsRedraw = true
    }

    public func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        // Cheap and correct for M1: rebuild from the surviving strokes.
        committedVertices = strokes.flatMap { stroke in
            Tessellator.tessellate(StrokeSmoother.resample(stroke.points), style: stroke.style)
        }
        renderer.setCommittedGeometry(committedVertices)
        needsRedraw = true
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

        if collector.isDrawing {
            let points = collector.renderPoints
            // Convert live points to world space before tessellating
            let worldPoints = toWorldSpace(points)
            let resampled = StrokeSmoother.resample(worldPoints)
            renderer.setLiveGeometry(Tessellator.tessellate(resampled, style: style))
            needsRedraw = true
        }

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
        let translation = gesture.translation(in: self)
        camera.pan(by: Vec2(Double(translation.x), Double(translation.y)))
        gesture.setTranslation(.zero, in: self)
        needsRedraw = true
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: self)
        let anchor = Vec2(Double(location.x), Double(location.y))
        let viewSize = Vec2(Double(bounds.width), Double(bounds.height))

        camera.zoom(by: Float(gesture.scale), anchor: anchor, viewSize: viewSize)
        gesture.scale = 1.0
        needsRedraw = true
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
        return !collector.isDrawing
    }

    /// Only allow finger touches for gestures, not the Pencil.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Pencil should not trigger pan/zoom gestures
        return touch.type != .pencil
    }
}
#endif
