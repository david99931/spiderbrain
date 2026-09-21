import SwiftUI
import SpiderbrainKit

/// Types text into a node.
///
/// A sheet rather than editing on the canvas itself: text editing inside a Metal
/// view means owning a cursor, selection, and key handling, which is a lot of
/// machinery to build before knowing whether typed nodes are useful at all.
struct NodeTextEditor: View {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(initialText: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .focused($focused)
                .navigationTitle("Node Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onCommit(text) }
                    }
                }
        }
        .onAppear { focused = true }
    }
}

/// Works out how big a node has to be to hold a string.
///
/// Lives app-side because text layout needs a font, which `InkCore` has no
/// business knowing. Measures in world units — node bounds are world-space, so
/// the box comes out the same size regardless of how far the camera is zoomed.
enum NodeTextMeasurer {

    /// Wrapping width in world units. Past this, text wraps rather than growing
    /// sideways forever.
    private static let wrapWidth: Double = 260

    /// Font size in world units, matching roughly the scale of handwriting.
    private static let fontSize: Double = 17

    private static let padding: Double = 16

    /// A box large enough to render `text`, origin ignored by the caller.
    static func boundsFitting(_ text: String) -> Rect {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Rect(x: 0, y: 0, width: 0, height: 0) }

        let attributed = NSAttributedString(
            string: trimmed,
            attributes: [.font: UIFont.systemFont(ofSize: fontSize)]
        )
        let measured = attributed.boundingRect(
            with: CGSize(width: wrapWidth - padding * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return Rect(
            x: 0,
            y: 0,
            width: Double(ceil(measured.width)) + padding * 2,
            height: Double(ceil(measured.height)) + padding * 2
        )
    }
}
