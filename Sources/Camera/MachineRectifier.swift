import CoreGraphics
import CoreVideo
import Foundation
import simd

/// The two corrections that turn the measured machine into the picture a
/// player sees standing square in front of the cabinet.
///
/// The screen is a circle on the real machine, so an ellipse in the picture
/// means the camera is tilted; pulling that ellipse back to a circle removes
/// the tilt and keeps the frame rectangular while it does it, because the
/// correction is a 2x2 map and not a pair of stretched axes.
///
/// What is left after that is a radius that still varies with the direction:
/// the screen can be round while the ring of eight buttons around it is not.
/// The eight decorative frames are one part repeated eight times, so a
/// head-on picture has them at one distance from the screen centre in all
/// eight directions.  Measuring them gives that variation directly, and a
/// few harmonics give a smooth multiplier that walks every direction onto
/// the same circle.  This is the same pair of steps the offline pipeline
/// runs in `pc/canonical.py`.
enum MachineRectifier {
    static let slotCount = 8
    static let slotStep: CGFloat = 45

    /// Tile centre radius over screen radius on a head-on picture, measured
    /// with the same detectors the lock uses.
    ///
    /// The offline pipeline reads the tile face's blob centroid and gets
    /// 1.23; the phone cannot run a connected-component pass per frame, so it
    /// walks eight rays instead and takes the middle of the purple stretch on
    /// each one.  On the head-on reference (`H:/IMG_8839(20261002-154029).JPG`,
    /// 2875x2908, cyan screen radius 1060.8px) those two statistics agree:
    /// blob centroids average 1.23, the ray middles average 1.239.  Keep the
    /// number tied to the statistic, not to the feature.
    static let tileRatio: Float = 1.23

    /// The eight slots, in the operator's numbering: 1 upper-right,
    /// clockwise, 8 straight up.  Angles are y-up degrees.
    static var slotAngles: [CGFloat] {
        (0..<slotCount).map { 22.5 + slotStep * CGFloat($0) }
    }

    /// 2x2 that takes the screen ellipse to a circle of the same area.
    ///
    /// `majorAxis` and `minorAxis` are the ellipse's semi-axis vectors in the
    /// locked output plane, after the fisheye has been undone.  Blending
    /// towards the identity happens on the axis *scales*, so the map stays
    /// positive definite at every slider position instead of passing through a
    /// singular pair of axes halfway.
    static func shape(
        majorAxis: CGPoint,
        minorAxis: CGPoint,
        strength: Double
    ) -> simd_float2x2 {
        let majorLength = hypot(majorAxis.x, majorAxis.y)
        let minorLength = hypot(minorAxis.x, minorAxis.y)
        guard majorLength > 1, minorLength > 1,
              strength > 0, strength.isFinite else { return matrix_identity_float2x2 }

        let target = sqrt(majorLength * minorLength)
        let blend = CGFloat(min(max(strength, 0), 1))
        let scaleMajor = 1 - blend + blend * target / majorLength
        let scaleMinor = 1 - blend + blend * target / minorLength

        let alongMajor = simd_float2(Float(majorAxis.x / majorLength),
                                     Float(majorAxis.y / majorLength))
        let alongMinor = simd_float2(Float(minorAxis.x / minorLength),
                                     Float(minorAxis.y / minorLength))
        let frame = simd_float2x2(columns: (alongMajor, alongMinor))
        let scales = simd_float2x2(diagonal: SIMD2<Float>(Float(scaleMajor),
                                                          Float(scaleMinor)))
        return frame * scales * frame.transpose
    }

    /// Least-squares fit of `rho(theta) = c0 + a1 cos t + b1 sin t + ...`
    /// against the eight slot readings.  A tilt shows up as one turn around
    /// the ring, a squash as two, and the rest of the lens as three; eight
    /// samples cannot say anything beyond that.
    static func fitHarmonics(
        _ ratios: [Float],
        order: Int = 3
    ) -> (cosine: SIMD4<Float>, sine: SIMD4<Float>)? {
        let angles = slotAngles
        let known = ratios.indices.filter { ratios[$0].isFinite && ratios[$0] > 0 }
        guard known.count >= 2 * order + 2 else { return nil }

        let columns = 2 * order + 1
        var normal = [[Double]](repeating: [Double](repeating: 0, count: columns),
                                count: columns)
        var rhs = [Double](repeating: 0, count: columns)
        for index in known {
            let t = Double(angles[index]) * .pi / 180
            var row = [1.0]
            for harmonic in 1...order {
                row.append(cos(Double(harmonic) * t))
                row.append(sin(Double(harmonic) * t))
            }
            let value = Double(ratios[index])
            for a in 0..<columns {
                for b in 0..<columns { normal[a][b] += row[a] * row[b] }
                rhs[a] += row[a] * value
            }
        }
        guard let solution = solve(normal, rhs) else { return nil }
        let cosine = SIMD4<Float>(Float(solution[0]),
                                  Float(solution[1]),
                                  Float(order >= 2 ? solution[3] : 0),
                                  Float(order >= 3 ? solution[5] : 0))
        let sine = SIMD4<Float>(Float(solution[2]),
                                Float(order >= 2 ? solution[4] : 0),
                                Float(order >= 3 ? solution[6] : 0),
                                0)
        return (cosine, sine)
    }

    /// The highest order the slots that were actually found can support.
    ///
    /// Three harmonics are eight unknowns, so they need all eight slots; two
    /// need six and one needs four.  The scanner misses a slot whenever a
    /// finger or a highlight covers a tile, and dropping straight to "no
    /// correction at all" in that case would switch the ring off for whole
    /// seconds at a time, which reads as the lock letting go.
    static func fitBest(_ ratios: [Float]) -> (cosine: SIMD4<Float>, sine: SIMD4<Float>)? {
        let known = ratios.filter { $0.isFinite && $0 > 0 }.count
        let order: Int
        if known >= 8 {
            order = 3
        } else if known >= 6 {
            order = 2
        } else if known >= 4 {
            order = 1
        } else {
            return nil
        }
        return fitHarmonics(ratios, order: order)
    }

    /// Gaussian elimination with partial pivoting; the fits here are tiny.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let count = rhs.count
        var a = matrix
        var b = rhs
        for column in 0..<count {
            var pivot = column
            for row in (column + 1)..<count where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }
            for row in (column + 1)..<count {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<count { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var out = [Double](repeating: 0, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<count { sum -= a[row][k] * out[k] }
            out[row] = sum / a[row][row]
        }
        return out.allSatisfy { $0.isFinite } ? out : nil
    }
}

/// Carries a point between the rectified preview plane and the locked output
/// plane.
///
/// The Metal shader pulls the screen ellipse and the button ring straight in
/// its own output rays, so both features have to be measured in that plane.
/// The detector works in the preview plane, which differs from it by the view
/// rotation that centres the screen — a few degrees when the machine is
/// already centred, but tens of degrees right after the lock catches a cabinet
/// at the edge of the frame, and a tilted ellipse measured in the wrong plane
/// is a tilted correction.
///
/// `outputToPreview` is the same 3x3 the shader uses: a ray in locked output
/// coordinates is mapped to the preview camera by multiplying with it.
struct MachinePlaneMap {
    var outputToPreview: simd_float3x3
    var previewSize: CGSize
    var horizontalFOV: Double

    var focal: CGFloat {
        guard previewSize.width > 1 else { return 1 }
        let radians = min(max(horizontalFOV, 1), 179) * .pi / 180
        return previewSize.width / (2 * tan(CGFloat(radians) * 0.5))
    }

    private var isUsable: Bool {
        previewSize.width > 1 && previewSize.height > 1 && focal > 1
    }

    /// Ray coordinates in the locked planes for a normalised preview point.
    func lockedPlane(_ previewPoint: CGPoint) -> CGPoint? {
        guard isUsable else { return nil }
        let f = focal
        let ray = simd_normalize(SIMD3<Float>(
            Float((previewPoint.x - 0.5) * previewSize.width / f),
            Float((previewPoint.y - 0.5) * previewSize.height / f),
            1
        ))
        // The view rotation is orthonormal, so its inverse is its transpose.
        let output = simd_normalize(outputToPreview.transpose * ray)
        guard output.z > 0.05, output.x.isFinite, output.y.isFinite else { return nil }
        return CGPoint(x: CGFloat(output.x / output.z), y: CGFloat(output.y / output.z))
    }

    /// The normalised preview point that a locked-plane ray reads.
    func previewNormalized(lockedPlane point: CGPoint) -> CGPoint? {
        guard isUsable else { return nil }
        let ray = simd_normalize(SIMD3<Float>(Float(point.x), Float(point.y), 1))
        let preview = simd_normalize(outputToPreview * ray)
        guard preview.z > 0.05 else { return nil }
        let f = focal
        let x = 0.5 + CGFloat(preview.x / preview.z) * f / previewSize.width
        let y = 0.5 + CGFloat(preview.y / preview.z) * f / previewSize.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Reads the eight decorative frames straight off the camera buffer.
///
/// The offline tool segments every purple pixel and takes blob centroids.
/// On the phone it is cheaper and steadier to walk eight rays from the
/// screen centre outwards and keep the purple stretch on each one: the same
/// quantity, about 1200 reads per frame instead of a connected-component
/// pass over the whole picture.
enum ButtonRingSampler {
    /// Blue-minus-green, the same test `tools/measure_button_frames.py` uses.
    static let purpleFloor = 32
    static let valueFloor = 70
    /// The tile spans roughly 0.8 to 1.6 screen radii, so the sweep has to
    /// cover a little more than that on both sides.
    static let band: ClosedRange<CGFloat> = 0.62...1.70
    /// A tile is about 0.4 screen radii thick; anything shorter on the ray is
    /// game content or a highlight, not the part.
    static let shortestRun: CGFloat = 0.12
    static let steps = 54

    struct Reading {
        var ratios: [Float] = Array(repeating: .nan, count: MachineRectifier.slotCount)
        var found = 0
        var mean: Float = 0
        var spread: Float = 0

        var isValid: Bool { found >= 5 && mean.isFinite && mean > 0 }
    }

    /// Measures the eight slots in the locked output plane.
    ///
    /// `centerPreview` is the screen centre as a normalised preview point and
    /// `screenRadius` is the screen radius already expressed in that plane, so
    /// every radius this returns is directly comparable with the shader's
    /// `screenRadiusNorm`.
    static func measure(
        pixelBuffer: CVPixelBuffer,
        sourceSize: CGSize,
        settings: LensCorrectionSettings,
        map: MachinePlaneMap,
        centerPreview: CGPoint,
        screenRadius: CGFloat,
        subAngles: [CGFloat] = [-11, 0, 11],
        steps: Int = ButtonRingSampler.steps
    ) -> Reading {
        var reading = Reading()
        guard screenRadius > 1e-3,
              sourceSize.width > 2, sourceSize.height > 2,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return reading
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let centerLocked = map.lockedPlane(centerPreview) else { return reading }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 2, height > 2 else { return reading }

        func isPurple(at source: CGPoint) -> Bool {
            let x = Int((source.x * CGFloat(width)).rounded())
            let y = Int((source.y * CGFloat(height)).rounded())
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            let blue = Int(pixel[0])
            let green = Int(pixel[1])
            let red = Int(pixel[2])
            return blue - green > purpleFloor
                && max(max(blue, green), red) > valueFloor
        }

        let stepCount = CGFloat(max(steps, 1))
        let bandWidth = band.upperBound - band.lowerBound
        let minRunSteps = shortestRun / bandWidth * stepCount
        var ratios: [Float] = []
        for angle in MachineRectifier.slotAngles {
            var found: [CGFloat] = []
            for offset in subAngles {
                let radians = (angle + offset) * .pi / 180
                // Slot angles are y-up degrees; the locked plane's y runs down.
                let direction = CGPoint(x: cos(radians), y: -sin(radians))
                var runs: [(first: CGFloat, last: CGFloat)] = []
                var start: CGFloat?
                for step in 0...steps {
                    let fraction = CGFloat(step) / CGFloat(max(steps, 1))
                    let radius = (band.lowerBound
                        + (band.upperBound - band.lowerBound) * fraction) * screenRadius
                    let point = CGPoint(x: centerLocked.x + direction.x * radius,
                                        y: centerLocked.y + direction.y * radius)
                    guard let normalized = map.previewNormalized(lockedPlane: point) else {
                        continue
                    }
                    let source = LensCoordinateMapper.fisheyePoint(
                        fromRectified: normalized,
                        sourceSize: sourceSize,
                        previewSize: map.previewSize,
                        settings: settings
                    )
                    if isPurple(at: source) {
                        start = start ?? radius
                    } else if let first = start {
                        runs.append((first, radius))
                        start = nil
                    }
                }
                if let first = start { runs.append((first, band.upperBound * screenRadius)) }
                let stepSize = bandWidth * screenRadius / stepCount
                let thick = runs.filter {
                    ($0.last - $0.first) / max(stepSize, 1e-6) >= minRunSteps
                }
                if let longest = thick.max(by: { ($0.last - $0.first) < ($1.last - $1.first) }) {
                    found.append((longest.first + longest.last) * 0.5)
                }
            }
            ratios.append(found.isEmpty ? Float.nan : Float(median(found) / screenRadius))
        }
        reading.ratios = ratios
        let known = ratios.filter { $0.isFinite && $0 > 0 }
        reading.found = known.count
        if !known.isEmpty {
            let mean = known.reduce(0, +) / Float(known.count)
            reading.mean = mean
            let variance = known.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(known.count)
            reading.spread = mean > 0 ? sqrt(variance) / mean : 0
        }
        return reading
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) * 0.5
            : sorted[middle]
    }
}
