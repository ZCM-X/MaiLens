import CoreGraphics
import Foundation

enum LensCoordinateMapper {
    static func fisheyePoint(
        fromRectified point: CGPoint,
        sourceSize: CGSize,
        previewSize: CGSize,
        settings: LensCorrectionSettings
    ) -> CGPoint {
        guard settings.correctionEnabled,
              sourceSize.width > 0,
              sourceSize.height > 0,
              previewSize.width > 0,
              previewSize.height > 0 else { return point }

        let sourceWidth = Double(sourceSize.width)
        let sourceHeight = Double(sourceSize.height)
        let focal = Double(max(sourceSize.width, sourceSize.height)) * 772.4089 / 4032.0
        let virtualFocal = Double(previewSize.width) / (2.0 * tan(settings.horizontalFOV * .pi / 360.0))
        let rayX = (Double(point.x) - 0.5) * Double(previewSize.width) / virtualFocal
        let rayY = (Double(point.y) - 0.5) * Double(previewSize.height) / virtualFocal
        let radius = hypot(rayX, rayY)
        let theta = atan(radius)
        let theta2 = theta * theta
        let distortedTheta = theta * (1.0 + settings.k1 * theta2 + settings.k2 * theta2 * theta2)
        let radialScale = radius > 0.000001 ? distortedTheta / radius : 1.0
        let sourceX = settings.centerX * sourceWidth + focal * rayX * radialScale
        let sourceY = settings.centerY * sourceHeight + focal * rayY * radialScale
        return CGPoint(x: sourceX / sourceWidth, y: sourceY / sourceHeight)
    }

    static func rectifiedPoint(
        fromFisheye point: CGPoint,
        sourceSize: CGSize,
        previewSize: CGSize,
        settings: LensCorrectionSettings
    ) -> CGPoint {
        guard settings.correctionEnabled,
              sourceSize.width > 0,
              sourceSize.height > 0,
              previewSize.width > 0,
              previewSize.height > 0 else { return point }

        let sourceWidth = Double(sourceSize.width)
        let sourceHeight = Double(sourceSize.height)
        let focal = Double(max(sourceSize.width, sourceSize.height)) * 772.4089 / 4032.0
        let distortedX = (Double(point.x) - settings.centerX) * sourceWidth / focal
        let distortedY = (Double(point.y) - settings.centerY) * sourceHeight / focal
        let distortedRadius = hypot(distortedX, distortedY)
        guard distortedRadius > 0.000001 else { return CGPoint(x: 0.5, y: 0.5) }

        var theta = min(distortedRadius, 1.45)
        for _ in 0..<7 {
            let theta2 = theta * theta
            let theta4 = theta2 * theta2
            let residual = theta * (1.0 + settings.k1 * theta2 + settings.k2 * theta4) - distortedRadius
            let derivative = 1.0 + 3.0 * settings.k1 * theta2 + 5.0 * settings.k2 * theta4
            guard abs(derivative) > 0.000001 else { break }
            theta = min(max(theta - residual / derivative, 0.0), 1.45)
        }

        let rectifiedRadius = tan(theta)
        let directionX = distortedX / distortedRadius
        let directionY = distortedY / distortedRadius
        let virtualFocal = Double(previewSize.width) / (2.0 * tan(settings.horizontalFOV * .pi / 360.0))
        let x = 0.5 + directionX * rectifiedRadius * virtualFocal / Double(previewSize.width)
        let y = 0.5 + directionY * rectifiedRadius * virtualFocal / Double(previewSize.height)
        return CGPoint(x: x, y: y)
    }
}
