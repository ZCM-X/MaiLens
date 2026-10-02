import CoreGraphics
import Foundation

struct LensCorrectionSettings: Codable, Equatable {
    var profileName: String
    var centerX: Double
    var centerY: Double
    var k1: Double
    var k2: Double
    var horizontalFOV: Double
    var lensHalfFOV: Double
    var imageCircleRatio: Double
    var correctionEnabled: Bool

    static let storageKey = "maiLens.lensCorrectionSettings.v1"
    private static let defaultLensHalfFOV = 69.0
    private static let defaultImageCircleRatio = 1.15
    private static let mistaken75DegreeMigrationKey = "maiLens.migrated75DegreeAsMachineGap.v1"

    /// The bundled profile contains the clip-on lens geometry and the
    /// preliminary checkerboard fit for lens centre and radial distortion.
    static let preliminary: LensCorrectionSettings = loadBundledProfile() ?? LensCorrectionSettings(
        profileName: "iPhone 15 Pro Max · 外夹鱼眼",
        centerX: 2023.0716 / 4032.0,
        centerY: 1510.2571 / 3024.0,
        k1: 0.0893163,
        k2: -0.0174637,
        horizontalFOV: 103,
        lensHalfFOV: Self.defaultLensHalfFOV,
        imageCircleRatio: Self.defaultImageCircleRatio,
        correctionEnabled: true
    )

    private static func loadBundledProfile() -> LensCorrectionSettings? {
        guard let url = Bundle.main.url(forResource: "MaiLens-Lens-Profile", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LensCorrectionSettings.self, from: data)
    }

    static func load() -> LensCorrectionSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(LensCorrectionSettings.self, from: data) else {
            UserDefaults.standard.set(true, forKey: mistaken75DegreeMigrationKey)
            return .preliminary
        }

        // Older saved profiles have no explicit fisheye projection geometry.
        // Keep their checkerboard centre/K values and add the lens projection
        // defaults from the bundled profile. Also repair a temporary 75°
        // default used while the machine's 75 mm border gap was mistaken for FOV.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let defaults = Self.preliminary
            let missingProjectionGeometry = object["lensHalfFOV"] == nil || object["imageCircleRatio"] == nil
            let hasRunFOVMigration = UserDefaults.standard.bool(forKey: mistaken75DegreeMigrationKey)
            let mistakenGapAsFOV = !hasRunFOVMigration && abs(value.horizontalFOV - 75) < 0.0001
            if missingProjectionGeometry || mistakenGapAsFOV {
                if mistakenGapAsFOV {
                    value.horizontalFOV = defaults.horizontalFOV
                }
                if object["lensHalfFOV"] == nil {
                    value.lensHalfFOV = defaults.lensHalfFOV
                }
                if object["imageCircleRatio"] == nil {
                    value.imageCircleRatio = defaults.imageCircleRatio
                }
                value.save()
            }
        }
        UserDefaults.standard.set(true, forKey: mistaken75DegreeMigrationKey)
        return value
    }

    /// Converts the configured half field of view and image-circle diameter
    /// into the source focal length used by both the Metal shader and Vision
    /// geometry mapper. The image-circle ratio is relative to the source
    /// image's short side.
    func sourceFocalLength(for sourceSize: CGSize) -> Double {
        let shortSide = max(min(Double(sourceSize.width), Double(sourceSize.height)), 1)
        let circleRadius = shortSide * max(imageCircleRatio, 0.01) * 0.5
        let halfAngle = min(max(lensHalfFOV, 1), 89) * .pi / 180
        let coefficient1 = correctionEnabled ? k1 : 0
        let coefficient2 = correctionEnabled ? k2 : 0
        let angle2 = halfAngle * halfAngle
        let angle4 = angle2 * angle2
        let distortedHalfAngle = halfAngle * (1 + coefficient1 * angle2 + coefficient2 * angle4)
        return circleRadius / max(distortedHalfAngle, 0.001)
    }

    private enum CodingKeys: String, CodingKey {
        case profileName, centerX, centerY, k1, k2, horizontalFOV
        case lensHalfFOV, imageCircleRatio, correctionEnabled
    }

    init(
        profileName: String,
        centerX: Double,
        centerY: Double,
        k1: Double,
        k2: Double,
        horizontalFOV: Double,
        lensHalfFOV: Double,
        imageCircleRatio: Double,
        correctionEnabled: Bool
    ) {
        self.profileName = profileName
        self.centerX = centerX
        self.centerY = centerY
        self.k1 = k1
        self.k2 = k2
        self.horizontalFOV = horizontalFOV
        self.lensHalfFOV = lensHalfFOV
        self.imageCircleRatio = imageCircleRatio
        self.correctionEnabled = correctionEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName) ?? "iPhone 15 Pro Max · 外夹鱼眼"
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        k1 = try values.decodeIfPresent(Double.self, forKey: .k1) ?? 0
        k2 = try values.decodeIfPresent(Double.self, forKey: .k2) ?? 0
        horizontalFOV = try values.decodeIfPresent(Double.self, forKey: .horizontalFOV) ?? 103
        lensHalfFOV = try values.decodeIfPresent(Double.self, forKey: .lensHalfFOV) ?? Self.defaultLensHalfFOV
        imageCircleRatio = try values.decodeIfPresent(Double.self, forKey: .imageCircleRatio) ?? Self.defaultImageCircleRatio
        correctionEnabled = try values.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? true
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func exportURL() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaiLens-Lens-Profile.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct LensProfileFile: Identifiable {
    let id = UUID()
    let url: URL
}
