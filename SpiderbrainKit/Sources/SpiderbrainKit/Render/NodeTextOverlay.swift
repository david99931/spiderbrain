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
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Touches pass straight through unless a text view is actively being edited.
    ///
    /// Every node has a text view, including empty ones, so letting them catch
    /// touches would mean a tap anywhere on a node hit an invisible box instead of
    /// selecting, dragging, or drawing. The overlay's own double-tap recognizer
    /// (added in `init`) is what activates a text view; until then the overlay is
    /// invisible to touch.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)

        // Once a text view is first responder it needs its touches back, for the
        // cursor, selection handles, and the edit menu.
        if let textView = hit as? UITextView, textView.isFirstResponder {
            return textView
        }
        return nil
    }

    /// Put the cursor in whichever node covers this point.
    ///
    /// Driven from the canvas rather than a recognizer of our own: `hitTest`
    /// returns nil while nothing is being edited, which takes this view out of the
    /// responder chain entirely — gestures attached here would never fire.
    ///
    /// - Returns: whether a node's text was actually entered.
    @discardableResult
    public func beginEditing(at point: CGPoint) -> Bool {
        guard let view = textViews.values.first(where: { $0.frame.contains(point) })
        else { return false }

        view.isEditable = true
        view.isSelectable = true
        view.becomeFirstResponder()
        return true
    }

    /// Bring the overlay in line with the nodes and the camera.
    ///
    /// Called every frame the canvas redraws, from the same place the renderer
    /// reads the camera — anywhere else and the text lags the ink by a frame
    /// while panning.
    public func sync(nodes: [Node], transform: ViewTransform) {
        // Every node gets a text view, not just the ones with text — an empty
        // node has to be double-tappable to start typing into it.
        let liveIds = Set(nodes.map(\.id))

        // Drop views for nodes that went away.
        for (id, view) in textViews where !liveIds.contains(id) {
            view.removeFromSuperview()
            textViews.removeValue(forKey: id)
        }

        for node in nodes {
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

        // Inert until double-tapped, so a single tap passes through to the canvas
        // and selects, drags, or resizes the node like any other.
        //
        // `isSelectable` has to go too, not just `isEditable`: a selectable text
        // view still consumes touches for its own selection gestures, which is
        // what was swallowing every tap. The cost is that selecting text to copy
        // requires entering the node first — the usual behaviour for a field.
        view.isEditable = false
        view.isSelectable = false

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
        // Back to inert, so single taps reach the canvas again.
        textView.isEditable = false
        textView.isSelectable = false

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
