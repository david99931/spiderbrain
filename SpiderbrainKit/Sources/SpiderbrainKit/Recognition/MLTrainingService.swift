#if os(iOS)
import Foundation
import CoreML
import Vision

/// Service for managing ML training data export and model usage
/// Note: Actual training must be done on macOS using Create ML
public class MLTrainingService {

    /// Training requirements
    private enum TrainingRequirements {
        static let minimumTotalCorrections = 20
        static let minimumSamplesPerWord = 10
        static let minimumTrainableWords = 2
    }

    /// Training status
    public enum TrainingStatus {
        case notReady(reason: String)
        case ready(words: Int, samples: Int)
        case exportReady(exportURL: URL, words: Int, samples: Int)
        case completed(modelVersion: Int)
        case failed(Error)
    }

    /// Training errors
    public enum TrainingError: Error {
        case insufficientData
        case exportFailed
        case noModelFound
    }

    private let correctionStorage = CorrectionStorageManager()

    public init() {}

    /// Check if we have enough data to export for training
    public func checkTrainingReadiness() -> TrainingStatus {
        let stats = correctionStorage.getStatistics()

        // Check minimum total corrections
        if stats.totalCorrections < TrainingRequirements.minimumTotalCorrections {
            return .notReady(reason: "Need \(TrainingRequirements.minimumTotalCorrections) corrections (have \(stats.totalCorrections))")
        }

        // Check trainable words (words with 10+ samples)
        if stats.trainableWords < TrainingRequirements.minimumTrainableWords {
            return .notReady(reason: "Need \(TrainingRequirements.minimumTrainableWords) words with \(TrainingRequirements.minimumSamplesPerWord)+ samples (have \(stats.trainableWords))")
        }

        return .ready(words: stats.trainableWords, samples: stats.unusedCorrections)
    }

    /// Export training data for use on macOS
    /// Returns URL to exported directory that can be shared/copied to Mac for training
    public func exportTrainingData() -> TrainingStatus {
        // Check readiness
        let readiness = checkTrainingReadiness()
        guard case .ready(let words, let samples) = readiness else {
            return readiness
        }

        // Load corrections
        let corrections = correctionStorage.loadCorrections()
        let unusedCorrections = corrections.filter { !$0.usedForTraining }

        // Group by word and filter to only words with enough samples
        let wordGroups = Dictionary(grouping: unusedCorrections) { $0.userCorrection }
            .filter { $0.value.count >= TrainingRequirements.minimumSamplesPerWord }

        guard wordGroups.count >= TrainingRequirements.minimumTrainableWords else {
            return .failed(TrainingError.insufficientData)
        }

        do {
            // Prepare training directory in Documents (persistent location)
            let documentsPath = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let exportDir = documentsPath.appendingPathComponent("TrainingDataExport")

            // Remove old export if exists
            if FileManager.default.fileExists(atPath: exportDir.path) {
                try FileManager.default.removeItem(at: exportDir)
            }

            let trainingDataURL = try prepareTrainingData(
                wordGroups: wordGroups,
                exportDir: exportDir
            )

            print("✅ Training data exported to: \(trainingDataURL.path)")
            print("📦 Copy this folder to a Mac and use Create ML to train a model")

            return .exportReady(
                exportURL: trainingDataURL,
                words: wordGroups.count,
                samples: unusedCorrections.count
            )

        } catch {
            print("❌ Export failed: \(error)")
            return .failed(error)
        }
    }

    /// Prepare training data by organizing images into folders by word
    private func prepareTrainingData(
        wordGroups: [String: [CorrectionSample]],
        exportDir: URL
    ) throws -> URL {
        // Create export directory
        try FileManager.default.createDirectory(
            at: exportDir,
            withIntermediateDirectories: true
        )

        // Create README with instructions
        let readmeContent = """
        # Handwriting Training Data Export

        This directory contains handwriting samples organized by word for training a custom ML model.

        ## Structure
        - Each subfolder represents a word/class
        - Each image in the folder is a sample of that word

        ## Training on macOS
        1. Copy this entire folder to your Mac
        2. Open Xcode and create a new playground or Swift file
        3. Use Create ML to train an Image Classifier:

        ```swift
        import CreateML
        import Foundation

        let trainingData = try MLImageClassifier.DataSource.labeledDirectories(at: URL(fileURLWithPath: "/path/to/TrainingDataExport"))

        let model = try MLImageClassifier(trainingData: trainingData)

        try model.write(to: URL(fileURLWithPath: "/path/to/HandwritingModel.mlmodel"))
        ```

        4. Add the trained .mlmodel file to your Xcode project

        ## Statistics
        - Total words: \(wordGroups.count)
        - Total samples: \(wordGroups.values.map { $0.count }.reduce(0, +))

        Generated: \(Date())
        """

        let readmeURL = exportDir.appendingPathComponent("README.md")
        try readmeContent.write(to: readmeURL, atomically: true, encoding: .utf8)

        // For each word, create a folder and save images
        for (word, samples) in wordGroups {
            // Sanitize word for folder name
            let folderName = word.replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")

            let wordFolder = exportDir.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(
                at: wordFolder,
                withIntermediateDirectories: true
            )

            // Save each sample image
            for (index, sample) in samples.enumerated() {
                let imageURL = wordFolder.appendingPathComponent("sample_\(index).png")
                try sample.strokeImageData.write(to: imageURL)
            }
        }

        print("✅ Exported training data: \(wordGroups.count) words")
        return exportDir
    }

    /// Check if a trained model is available
    public func hasTrainedModel() -> Bool {
        // Check if HandwritingModel exists in bundle
        return Bundle.main.url(forResource: "HandwritingModel", withExtension: "mlmodelc") != nil
    }

    /// Get export directory URL
    public func getExportDirectory() -> URL? {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let exportDir = documentsPath.appendingPathComponent("TrainingDataExport")

        return FileManager.default.fileExists(atPath: exportDir.path) ? exportDir : nil
    }
}
#endif
