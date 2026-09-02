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
        ZStack(alignment: .top) {
            Group {
                switch engine {
                case .metal:
                    MetalInkCanvas(
                        mode: mode,
                        predictionEnabled: predictionEnabled,
                        clearToken: clearToken,
                        undoToken: undoToken,
                        onStats: { stats = $0 }
                    )
                    .id("metal")
                case .pencilKit:
                    PencilKitCanvas(clearToken: clearToken)
                        .id("pencilkit")
                }
            }
            .ignoresSafeArea()

            controls
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
}

// MARK: - Bridges

private struct MetalInkCanvas: UIViewRepresentable {
    var mode: ContentView.DrawMode
    var predictionEnabled: Bool
    var clearToken: Int
    var undoToken: Int
    var onStats: (MetalInkView.HUDStats) -> Void

    func makeUIView(context: Context) -> MetalInkView {
        guard let view = MetalInkView(frame: .zero) else {
            fatalError("Metal is unavailable. Run on a device, not the simulator.")
        }
        view.onStatsUpdate = onStats
        context.coordinator.lastClear = clearToken
        context.coordinator.lastUndo = undoToken
        return view
    }

    func updateUIView(_ view: MetalInkView, context: Context) {
        // Update mode
        view.drawMode = mode == .draw ? .draw : .lasso

        view.predictionEnabled = predictionEnabled
        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            view.clear()
        }
        if context.coordinator.lastUndo != undoToken {
            context.coordinator.lastUndo = undoToken
            view.undoLastStroke()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastClear = 0
        var lastUndo = 0
    }
}

private struct PencilKitCanvas: UIViewControllerRepresentable {
    var clearToken: Int

    func makeUIViewController(context: Context) -> PKCanvasViewController {
        PKCanvasViewController(clearToken: clearToken)
    }

    func updateUIViewController(_ vc: PKCanvasViewController, context: Context) {
        if context.coordinator.lastClear != clearToken {
            context.coordinator.lastClear = clearToken
            vc.canvasView.drawing = PKDrawing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastClear = 0
    }
}

private class PKCanvasViewController: UIViewController {
    let canvasView = PKCanvasView()

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
}
