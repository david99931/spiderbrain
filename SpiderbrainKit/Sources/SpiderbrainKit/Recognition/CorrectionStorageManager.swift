import Foundation

/// Manages persistence of correction samples to disk
public class CorrectionStorageManager {
    private let fileURL: URL

    public init() {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        self.fileURL = documentsPath.appendingPathComponent("corrections.json")
    }

    /// Load all corrections from disk
    public func loadCorrections() -> [CorrectionSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode([CorrectionSample].self, from: data)) ?? []
    }

    /// Save corrections to disk
    public func saveCorrections(_ corrections: [CorrectionSample]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(corrections) else {
            print("❌ Failed to encode corrections")
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            print("✅ Saved \(corrections.count) corrections to disk")
        } catch {
            print("❌ Failed to save corrections: \(error)")
        }
    }

    /// Add a new correction
    public func addCorrection(_ sample: CorrectionSample) {
        var corrections = loadCorrections()
        corrections.append(sample)
        saveCorrections(corrections)
    }

    /// Mark corrections as used for training
    public func markAsUsed(ids: [UUID], modelVersion: Int) {
        var corrections = loadCorrections()
        for i in corrections.indices {
            if ids.contains(corrections[i].id) {
                corrections[i].usedForTraining = true
                corrections[i].trainingModelVersion = modelVersion
            }
        }
        saveCorrections(corrections)
    }

    /// Get correction statistics
    public func getStatistics() -> CorrectionStatistics {
        let corrections = loadCorrections()
        let unusedCorrections = corrections.filter { !$0.usedForTraining }

        let wordCounts = Dictionary(grouping: unusedCorrections) { $0.userCorrection }
            .mapValues { $0.count }

        return CorrectionStatistics(
            totalCorrections: corrections.count,
            unusedCorrections: unusedCorrections.count,
            wordCounts: wordCounts,
            trainableWords: wordCounts.filter { $0.value >= 10 }.count
        )
    }

    /// Check if a Vision result has been corrected before
    /// Returns the most common user correction for this Vision result
    public func findCorrection(for visionResult: String) -> String? {
        let corrections = loadCorrections()
        let matchingCorrections = corrections.filter { $0.visionResult == visionResult }

        guard !matchingCorrections.isEmpty else { return nil }

        // Return most frequently used correction for this Vision result
        let correctionCounts = Dictionary(grouping: matchingCorrections) { $0.userCorrection }
            .mapValues { $0.count }

        return correctionCounts.max(by: { $0.value < $1.value })?.key
    }
}

/// Statistics about stored corrections
public struct CorrectionStatistics {
    public let totalCorrections: Int
    public let unusedCorrections: Int
    public let wordCounts: [String: Int]
    public let trainableWords: Int

    public init(
        totalCorrections: Int,
        unusedCorrections: Int,
        wordCounts: [String: Int],
        trainableWords: Int
    ) {
        self.totalCorrections = totalCorrections
        self.unusedCorrections = unusedCorrections
        self.wordCounts = wordCounts
        self.trainableWords = trainableWords
    }
}
