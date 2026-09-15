#if os(iOS)
import UIKit

/// Captures Apple Pencil input at full fidelity.
///
/// Three things here are easy to skip and all three are visible in the result:
///
/// 1. **Coalesced touches.** The Pencil samples at up to 240 Hz but `touchesMoved`
///    fires at display rate. Reading only the primary touch throws away most of the
///    stroke and produces faceted curves on fast movement.
/// 2. **Predicted touches.** UIKit extrapolates where the pen is heading. Drawing
///    them as a provisional tip is the single biggest perceived-latency win
///    available to a custom renderer. They must be replaced every event, never
///    accumulated, or the stroke grows a permanent tail of guesses.
/// 3. **Estimated properties.** Force, altitude and azimuth arrive as estimates and
///    are corrected milliseconds later via `touchesEstimatedPropertiesUpdated`.
///    Ignore the correction and pressure data is quietly wrong.
public final class StrokeInputCollector {

    /// Real samples, in order. These become the committed stroke.
    public private(set) var committed: [InkPoint] = []

    /// Extrapolated samples for the current frame only. Cleared on every update.
    public private(set) var predicted: [InkPoint] = []

    /// Set false to feel the difference prediction makes. Wire it to a switch.
    public var predictionEnabled = true

    /// Maps a Pencil estimation index back to its slot in `committed`.
    private var slotForEstimationIndex: [Int: Int] = [:]

    /// Counters for the debug HUD.
    public private(set) var coalescedCount = 0
    public private(set) var predictedCount = 0
    public private(set) var estimateCorrections = 0

    public init() {}

    public var isDrawing: Bool { !committed.isEmpty }

    /// Samples to render this frame: real points plus the provisional tip.
    public var renderPoints: [InkPoint] {
        predictionEnabled ? committed + predicted : committed
    }

    // MARK: - Lifecycle

    public func begin(_ touch: UITouch, in view: UIView) {
        reset()
        append(sample(from: touch, in: view))
    }

    /// Call from `touchesMoved`. Pass the event so coalesced and predicted touches
    /// can be read — without it you only get one sample per frame.
    public func update(with touch: UITouch, event: UIEvent?, in view: UIView) {
        predicted.removeAll(keepingCapacity: true)

        if let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
            coalescedCount += coalesced.count
            for coalescedTouch in coalesced {
                append(sample(from: coalescedTouch, in: view))
            }
        } else {
            append(sample(from: touch, in: view))
        }

        guard predictionEnabled, let upcoming = event?.predictedTouches(for: touch) else { return }
        predictedCount += upcoming.count
        for predictedTouch in upcoming {
            // Predicted samples never enter `committed`, so they carry no estimation
            // index — a correction could not meaningfully apply to a discarded guess.
            var point = sample(from: predictedTouch, in: view)
            point.estimationIndex = nil
            point.expectsUpdates = false
            predicted.append(point)
        }
    }

    /// Call from `touchesEnded`. Drops predictions and returns the real stroke.
    public func finish(_ touch: UITouch, in view: UIView) -> [InkPoint] {
        predicted.removeAll(keepingCapacity: true)
        append(sample(from: touch, in: view))
        return committed
    }

    public func reset() {
        committed.removeAll(keepingCapacity: true)
        predicted.removeAll(keepingCapacity: true)
        slotForEstimationIndex.removeAll(keepingCapacity: true)
        coalescedCount = 0
        predictedCount = 0
        estimateCorrections = 0
    }

    // MARK: - Estimated property corrections

    /// Call from `UIResponder.touchesEstimatedPropertiesUpdated`.
    ///
    /// The touch carries corrected values and the index of the sample they belong
    /// to. Patch that sample in place; the stroke re-tessellates on the next frame
    /// and the corrected pressure appears.
    public func applyEstimatedUpdate(_ touch: UITouch) {
        guard let indexNumber = touch.estimationUpdateIndex else { return }
        let index = indexNumber.intValue
        guard let slot = slotForEstimationIndex[index], slot < committed.count else { return }

        let updated = touch.estimatedProperties
        var point = committed[slot]

        if !updated.contains(.force) {
            point.force = normalisedForce(touch)
        }
        if !updated.contains(.altitude) {
            point.altitude = touch.altitudeAngle
        }

        point.expectsUpdates = !touch.estimatedPropertiesExpectingUpdates.isEmpty
        if !point.expectsUpdates {
            point.estimationIndex = nil
            slotForEstimationIndex.removeValue(forKey: index)
        }

        committed[slot] = point
        estimateCorrections += 1
    }

    // MARK: - Sampling

    private func append(_ point: InkPoint) {
        committed.append(point)
        if let index = point.estimationIndex, point.expectsUpdates {
            slotForEstimationIndex[index] = committed.count - 1
        }
    }

    private func sample(from touch: UITouch, in view: UIView) -> InkPoint {
        // preciseLocation gives subpixel resolution for the Pencil; location() does not.
        let location = touch.preciseLocation(in: view)
        let expecting = touch.estimatedPropertiesExpectingUpdates

        return InkPoint(
            position: Vec2(Double(location.x), Double(location.y)),
            force: normalisedForce(touch),
            altitude: touch.altitudeAngle,
            azimuth: touch.azimuthAngle(in: view),
            timestamp: touch.timestamp,
            estimationIndex: touch.estimationUpdateIndex?.intValue,
            expectsUpdates: !expecting.isEmpty
        )
    }

    /// Fingers and pointers report no useful force, so they get a fixed
    /// mid-pressure rather than zero — otherwise those strokes would come out at
    /// `minWidth` everywhere.
    private func normalisedForce(_ touch: UITouch) -> Double {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 0.55 }
        return clamp(Double(touch.force / touch.maximumPossibleForce), 0, 1)
    }
}
#endif
