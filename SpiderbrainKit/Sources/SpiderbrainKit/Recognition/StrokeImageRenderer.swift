#if os(iOS)
import UIKit
import Foundation

/// Renders strokes to UIImage for Vision Framework and ML model recognition.
public class StrokeImageRenderer {

    /// Configuration for rendering strokes to images
    public struct RenderConfig {
        public let backgroundColor: UIColor
        public let strokeColor: UIColor
        public let scale: CGFloat
        public let padding: CGFloat

        public static let `default` = RenderConfig(
            backgroundColor: .white,
            strokeColor: .black,
            scale: 2.0,  // Retina quality for better recognition
            padding: 20.0  // Border padding around strokes
        )

        public init(
            backgroundColor: UIColor = .white,
            strokeColor: UIColor = .black,
            scale: CGFloat = 2.0,
            padding: CGFloat = 20.0
        ) {
            self.backgroundColor = backgroundColor
            self.strokeColor = strokeColor
            self.scale = scale
            self.padding = padding
        }
    }

    /// Render strokes to a high-resolution image for text recognition
    /// - Parameters:
    ///   - strokes: The strokes to render
    ///   - bounds: The bounding box of the strokes in world coordinates
    ///   - targetSize: Target image size (default 512x512 for good recognition accuracy)
    ///   - config: Rendering configuration
    /// - Returns: UIImage with strokes rendered on white background
    public static func render(
        strokes: [Stroke],
        bounds: Rect,
        targetSize: CGSize = CGSize(width: 512, height: 512),
        config: RenderConfig = .default
    ) -> UIImage {
        guard !strokes.isEmpty else {
            return createEmptyImage(size: targetSize, config: config)
        }

        // Calculate scale to fit strokes into target size (with padding)
        let availableWidth = targetSize.width - (config.padding * 2)
        let availableHeight = targetSize.height - (config.padding * 2)

        let scaleX = availableWidth / bounds.width
        let scaleY = availableHeight / bounds.height
        let scale = min(scaleX, scaleY)

        // Calculate actual content size
        let contentWidth = bounds.width * scale
        let contentHeight = bounds.height * scale

        // Center the content
        let offsetX = (targetSize.width - contentWidth) / 2
        let offsetY = (targetSize.height - contentHeight) / 2

        // Create image context
        let format = UIGraphicsImageRendererFormat()
        format.scale = config.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let image = renderer.image { context in
            let ctx = context.cgContext

            // Fill background
            ctx.setFillColor(config.backgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: targetSize))

            // Set stroke color
            ctx.setStrokeColor(config.strokeColor.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Render each stroke
            for stroke in strokes {
                guard !stroke.points.isEmpty else { continue }

                // Start path
                ctx.beginPath()

                // Move to first point (transformed to image space)
                let firstPoint = transformPoint(
                    stroke.points[0].position,
                    bounds: bounds,
                    scale: scale,
                    offsetX: offsetX,
                    offsetY: offsetY
                )
                ctx.move(to: firstPoint)

                // Draw lines to remaining points
                for point in stroke.points.dropFirst() {
                    let transformedPoint = transformPoint(
                        point.position,
                        bounds: bounds,
                        scale: scale,
                        offsetX: offsetX,
                        offsetY: offsetY
                    )
                    ctx.addLine(to: transformedPoint)

                    // Use point's pressure for line width (convert to pixels)
                    let width = CGFloat(stroke.style.pressure.minWidth +
                                      (stroke.style.pressure.maxWidth - stroke.style.pressure.minWidth) * point.force)
                    ctx.setLineWidth(width * scale)
                }

                // Stroke the path
                ctx.strokePath()
            }
        }

        return image
    }

    /// Transform a point from world coordinates to image coordinates
    private static func transformPoint(
        _ point: Vec2,
        bounds: Rect,
        scale: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> CGPoint {
        // Translate point relative to bounds origin
        let relativeX = point.x - bounds.x
        let relativeY = point.y - bounds.y

        // Scale and offset
        let imageX = relativeX * scale + offsetX
        let imageY = relativeY * scale + offsetY

        return CGPoint(x: imageX, y: imageY)
    }

    /// Create an empty white image
    private static func createEmptyImage(size: CGSize, config: RenderConfig) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = config.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            config.backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
#endif
