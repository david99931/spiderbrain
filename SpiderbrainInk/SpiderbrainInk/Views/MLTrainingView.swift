import SwiftUI
import SpiderbrainKit

struct MLTrainingView: View {
    @State private var trainingStatus: MLTrainingService.TrainingStatus?
    @State private var isTraining = false

    private let trainingService = MLTrainingService()
    private let correctionStorage = CorrectionStorageManager()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)

                        Text("Handwriting Learning")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Train a personalized model from your corrections")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Statistics
                    statisticsSection

                    // Training Status
                    if let status = trainingStatus {
                        statusSection(status: status)
                    }

                    // Export Button
                    if case .ready = trainingStatus {
                        Button(action: {
                            exportData()
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export Training Data")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                            .fontWeight(.semibold)
                        }
                        .padding(.horizontal)
                    }

                    Spacer()
                }
            }
            .navigationTitle("ML Training")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                checkStatus()
            }
        }
    }

    private var statisticsSection: some View {
        let stats = correctionStorage.getStatistics()

        return VStack(spacing: 12) {
            Text("Training Data")
                .font(.headline)

            VStack(spacing: 8) {
                StatRow(
                    icon: "doc.text",
                    label: "Total Corrections",
                    value: "\(stats.totalCorrections)"
                )

                StatRow(
                    icon: "tray.full",
                    label: "Unused Samples",
                    value: "\(stats.unusedCorrections)"
                )

                StatRow(
                    icon: "character.book.closed",
                    label: "Trainable Words",
                    value: "\(stats.trainableWords)",
                    detail: "10+ samples each"
                )
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func statusSection(status: MLTrainingService.TrainingStatus) -> some View {
        VStack(spacing: 12) {
            Text("Status")
                .font(.headline)

            Group {
                switch status {
                case .notReady(let reason):
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not Ready")
                                .fontWeight(.semibold)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                case .ready(let words, let samples):
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ready to Export")
                                .fontWeight(.semibold)
                            Text("\(words) words, \(samples) samples")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                case .exportReady(let exportURL, let words, let samples):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Export Complete")
                                    .fontWeight(.semibold)
                                Text("\(words) words, \(samples) samples")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Location:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(exportURL.lastPathComponent)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.blue)

                            Text("Use Files app to access and share")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }

                case .completed(let version):
                    HStack(spacing: 12) {
                        Image(systemName: "brain.filled.head.profile")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model Active")
                                .fontWeight(.semibold)
                            Text("Version \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                case .failed(let error):
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Failed")
                                .fontWeight(.semibold)
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func checkStatus() {
        trainingStatus = trainingService.checkTrainingReadiness()
    }

    private func exportData() {
        let result = trainingService.exportTrainingData()
        trainingStatus = result
    }
}

struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .fontWeight(.semibold)

                if let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
