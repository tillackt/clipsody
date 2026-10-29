import Foundation

/// Version as stamped into Info.plist by build.sh: marketing version, build number (commit count)
/// and the commit it was built from.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["ClipsodyCommit"] as? String
        let commitSuffix = commit.map { ", \($0)" } ?? ""
        return String(localized: "Version \(version) (Build \(build)\(commitSuffix))")
    }
}
