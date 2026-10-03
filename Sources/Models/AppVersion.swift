import Foundation

/// The version string shown in the corner under the preview.
///
/// It is read from the bundle rather than typed into the UI so the number
/// always matches the build that is actually installed.  Bump it in
/// `project.yml` (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`); the
/// fallbacks below only matter if a build ever goes out without them.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let build = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let version = (short?.isEmpty == false) ? short! : "1.0"
        guard let build, !build.isEmpty else { return "v\(version)" }
        return "v\(version) (\(build))"
    }
}
