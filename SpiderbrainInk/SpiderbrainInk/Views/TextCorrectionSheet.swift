import SwiftUI
import SpiderbrainKit

struct TextCorrectionSheet: View {
    let recognizedText: RecognizedText
    let nodeId: UUID
    let nodeStrokes: [Stroke]
    let nodeBounds: Rect
    let onCorrect: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var correctedText: String

    init(
        recognizedText: RecognizedText,
        nodeId: UUID,
        nodeStrokes: [Stroke],
        nodeBounds: Rect,
        onCorrect: @escaping (String) -> Void
    ) {
        self.recognizedText = recognizedText
        self.nodeId = nodeId
        self.nodeStrokes = nodeStrokes
        self.nodeBounds = nodeBounds
        self.onCorrect = onCorrect
        self._correctedText = State(initialValue: recognizedText.text)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Show what Vision recognized
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vision Recognized:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(recognizedText.text)
                            .font(.title3)
                            .fontWeight(.medium)

                        Spacer()

                        Text("\(Int(recognizedText.confidence * 100))%")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                }

                // Correction input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Correct to:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Enter correct text", text: $correctedText)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .autocorrectionDisabled()
                }

                // Info about learning
                if correctedText != recognizedText.text && !correctedText.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.blue)
                        Text("This correction will help the app learn your handwriting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }

                Spacer()

                // Actions
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Save Correction") {
                        onCorrect(correctedText)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(correctedText.isEmpty)
                }
            }
            .padding()
            .navigationTitle("Correct Recognition")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
