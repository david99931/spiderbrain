#if os(iOS)
import UIKit
import InkCore

/// Draws node text using real `UITextView`s layered over the canvas.
///
/// Text lives in UIKit rather than in the Metal pipeline because selection is a
/// requirement, and selection needs per-glyph layout, hit-testing, highlight
/// rendering, a cursor, and the system copy/paste and keyboard behaviour.
/// `UITextView` has all of that; reproducing a usable subset of it on top of a
/// triangle renderer is weeks of work for a worse result.
///
/// The cost is z-order: these views sit above *all* Metal content, so ink drawn
/// across a text node renders beneath it. Revisit by moving text into the Metal
/// pipeline (glyph atlas) if that becomes the wrong tradeoff.
public final class NodeTextOverlay: UIView {

    /// Called when the user finishes editing a node's text.
    public var onTextEdited: ((UUID, String) -> Void)?

    /// Called while editing, with the size the text now needs in world units, so
    /// the node can grow to fit as the user types.
    public var onTextSizeChanged: ((UUID, Double, Double) -> Void)?

    /// Font size in world units, so text scales with the canvas the way ink does.
    private static let worldFontSize: Double = 17

    /// Inset from the node's bounds to the text, in world units.
    private static let worldPadding: Double = 8

    private var textViews: [UUID: UITextView] = [:]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        // The overlay itself is just a container; taps land on the text views or
        // fall through to the canvas underneath.
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Only the text views should catch touches; everywhere else belongs to the
    /// canvas below, so drawing over an empty area still works.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// Bring the overlay in line with the nodes and the camera.
    ///
    /// Called every frame the canvas redraws, from the same place the renderer
    /// reads the camera — anywhere else and the text lags the ink by a frame
    /// while panning.
    public func sync(nodes: [Node], transform: ViewTransform) {
        let withText = nodes.filter { ($0.text?.isEmpty == false) }
        let liveIds = Set(withText.map(\.id))

        // Drop views for nodes that lost their text or went away.
        for (id, view) in textViews where !liveIds.contains(id) {
            view.removeFromSuperview()
            textViews.removeValue(forKey: id)
        }

        for node in withText {
            let view = textViews[node.id] ?? makeTextView(for: node.id)

            // Don't fight the user: leave the text alone while they are typing in it.
            if !view.isFirstResponder, view.text != node.text {
                view.text = node.text
            }

            position(view, for: node, transform: transform)
        }
    }

    // MARK: - Layout

    private func position(_ view: UITextView, for node: Node, transform: ViewTransform) {
        let origin = transform.worldToView(Vec2(node.bounds.x, node.bounds.y))
        let zoom = Double(transform.zoom)

        view.frame = CGRect(
            x: origin.x + Self.worldPadding * zoom,
            y: origin.y + Self.worldPadding * zoom,
            width: max(1, (node.bounds.width - Self.worldPadding * 2) * zoom),
            height: max(1, (node.bounds.height - Self.worldPadding * 2) * zoom)
        )

        // Scale the font with the camera so text behaves like ink rather than
        // floating at a fixed screen size.
        let pointSize = Self.worldFontSize * zoom
        if view.font?.pointSize != CGFloat(pointSize) {
            view.font = .systemFont(ofSize: CGFloat(pointSize))
        }
    }

    private func makeTextView(for nodeId: UUID) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        // Explicitly black rather than `.label`, which follows the system
        // appearance and turns white in dark mode — invisible on this canvas.
        view.textColor = .black
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = self
        view.nodeId = nodeId

        addSubview(view)
        textViews[nodeId] = view
        return view
    }

    /// World-space size the text in this view currently needs.
    private func worldSizeNeeded(for view: UITextView, zoom: Double) -> (width: Double, height: Double) {
        let fitted = view.sizeThatFits(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)
        )
        guard zoom > 0 else { return (0, 0) }

        return (
            width: Double(fitted.width) / zoom + Self.worldPadding * 2,
            height: Double(fitted.height) / zoom + Self.worldPadding * 2
        )
    }

    /// Zoom inferred from the current font size, so callbacks can convert back to
    /// world units without the overlay holding a camera of its own.
    private func currentZoom(of view: UITextView) -> Double {
        guard let pointSize = view.font?.pointSize, pointSize > 0 else { return 1 }
        return Double(pointSize) / Self.worldFontSize
    }
}

// MARK: - UITextViewDelegate

extension NodeTextOverlay: UITextViewDelegate {

    public func textViewDidChange(_ textView: UITextView) {
        guard let nodeId = textView.nodeId else { return }

        let zoom = currentZoom(of: textView)
        let needed = worldSizeNeeded(for: textView, zoom: zoom)
        onTextSizeChanged?(nodeId, needed.width, needed.height)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        guard let nodeId = textView.nodeId else { return }
        onTextEdited?(nodeId, textView.text ?? "")
    }
}

// MARK: - Associating a node with its text view

private var nodeIdKey: UInt8 = 0

private extension UITextView {
    var nodeId: UUID? {
        get { objc_getAssociatedObject(self, &nodeIdKey) as? UUID }
        set { objc_setAssociatedObject(self, &nodeIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
#endif
