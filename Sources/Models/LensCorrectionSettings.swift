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

    /// The machine-shot profile supplies the output FOV. The lens center and
    /// radial coefficients remain the user's preliminary checkerboard fit.
    static let preliminary: LensCorrectionSettings = loadBundledProfile() ?? LensCorrectionSettings(
        profileName: "iPhone 15 Pro Max · 外夹鱼眼 · 棋盘预校准",
        centerX: 2023.0716 / 4032.0,
        centerY: 1510.2571 / 3024.0,
        k1: 0.0893163,
        k2: -0.0174637,
        horizontalFOV: 106.45833432674408,
        correctionEnabled: true
    )

    private static func loadBundledProfile() -> LensCorrectionSettings? {
        guard let url = Bundle.main.url(forResource: "MaiLens-Lens-Profile", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LensCorrectionSettings.self, from: data)
    }

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
