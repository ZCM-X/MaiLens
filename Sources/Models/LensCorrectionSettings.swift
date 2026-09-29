import Foundation

struct LensCorrectionSettings: Codable, Equatable {
    var profileName: String
    var centerX: Double
    var centerY: Double
    var k1: Double
    var k2: Double
    var horizontalFOV: Double
    var correctionEnabled: Bool

    static let storageKey = "maiLens.lensCorrectionSettings.v1"

    /// Initialized from the user's preliminary checkerboard calibration. The
    /// source images do not cover the outer image circle, so these are a seed,
    /// not a validated final lens profile.
    static let preliminary = LensCorrectionSettings(
        profileName: "iPhone 15 Pro Max · 外夹鱼眼 · 棋盘预校准",
        centerX: 2023.0716 / 4032.0,
        centerY: 1510.2571 / 3024.0,
        k1: 0.0893163,
        k2: -0.0174637,
        horizontalFOV: 110,
        correctionEnabled: true
    )

    static func load() -> LensCorrectionSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(LensCorrectionSettings.self, from: data) else {
            return .preliminary
        }
        return value
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
