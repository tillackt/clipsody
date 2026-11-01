import ClipsodyCore
import Foundation

/// Downloads a release and puts it in place of the running app. Only an app signed with the release
/// certificate (`UpdateCheck.signingCertificateSHA256`), with Clipsody's bundle identifier and exactly
/// the announced, newer version is installed; anything else leaves the installed app untouched.
/// Downloads go to GitHub only (release page host and its asset host).
public struct UpdateInstaller: Sendable {
    public enum Step: Sendable, Equatable {
        case downloading, verifying, installing
    }

    public enum Failure: Error, Equatable {
        /// The app's folder cannot be written (e.g. /Applications for a standard user, or the app runs
        /// from the disk image or a translocated copy).
        case notWritable
        case download
        case checksumMismatch
        case noAppInDiskImage
        case untrustedSignature
        case wrongVersion
        case replaceFailed
    }

    public typealias Download = @Sendable (URL, URL, Int) async throws -> Void
    public typealias RunTool = @Sendable (String, [String]) throws -> Void
    public typealias ReadSignature = @Sendable (URL) -> UpdateSignature?

    /// A disk image of Clipsody is a few megabytes; anything far larger is not a real one.
    static let maxDiskImageBytes = 100 * 1024 * 1024
    static let maxChecksumBytes = 1_024

    private let download: Download
    private let runTool: RunTool
    private let readSignature: ReadSignature
    private var fileManager: FileManager { .default }

    /// The parameters are replaced in tests; the defaults download with `UpdateDownload`, run hdiutil
    /// and ditto, and verify with Security.framework.
    public init(download: @escaping Download = UpdateDownload.toFile,
                runTool: @escaping RunTool = UpdateInstaller.run,
                readSignature: @escaping ReadSignature = UpdateSignature.read) {
        self.download = download
        self.runTool = runTool
        self.readSignature = readSignature
    }

    /// Replaces the app at `appURL` with `release`. Returns once the new app is in place; the caller
    /// restarts it. `progress` is called before each step, on any thread.
    public func install(_ release: UpdateCheck.Release, currentVersion: String, replacing appURL: URL,
                        progress: @Sendable (Step) -> Void = { _ in }) async throws {
        guard UpdateCheck.isNewer(release, than: currentVersion) else { throw Failure.wrongVersion }
        let folder = appURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }
        // One update at a time, also across processes; the lock also keeps launch clean-up away from
        // a staging folder that is still in use.
        guard let lock = UpdateLock(for: folder) else { throw Failure.replaceFailed }
        defer { lock.release() }

        let work = fileManager.temporaryDirectory.appendingPathComponent("Clipsody-Update-\(UUID().uuidString)")
        let staging = folder.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: false)
            // Next to the app, on the same volume, so the two can be swapped in one step.
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw Failure.notWritable
        }
        defer {
            try? fileManager.removeItem(at: work)
            try? fileManager.removeItem(at: staging)
        }

        progress(.downloading)
        let diskImage = work.appendingPathComponent("Clipsody.dmg")
        let checksumFile = work.appendingPathComponent("Clipsody.dmg.sha256")
        do {
            try await download(release.checksumURL, checksumFile, Self.maxChecksumBytes)
            try await download(release.diskImageURL, diskImage, Self.maxDiskImageBytes)
        } catch {
            throw Failure.download
        }

        progress(.verifying)
        guard let checksum = try? Data(contentsOf: checksumFile), let expected = UpdateCheck.checksum(fromFile: checksum),
              let image = try? Data(contentsOf: diskImage, options: .mappedIfSafe),
              ImageIngest.sha256(image) == expected else {
            throw Failure.checksumMismatch
        }
        // The checksum comes from the same release and only catches damage; the signature of the disk
        // image shows it was built with the release certificate, before hdiutil reads its contents.
        guard let imageSignature = readSignature(diskImage),
              imageSignature.certificateSHA256 == UpdateCheck.signingCertificateSHA256,
              imageSignature.identifier == UpdateCheck.bundleIdentifier + ".dmg" else { throw Failure.untrustedSignature }
        let staged = staging.appendingPathComponent("Clipsody.app")
        try copyApp(from: diskImage, mountingAt: work.appendingPathComponent("mount"), to: staged)
        try verify(staged, as: release)

        progress(.installing)
        // Another installation may have happened meanwhile; replace only a version known to be older.
        guard let installed = installedVersion(at: appURL), installed < release.version else {
            throw Failure.wrongVersion
        }
        try swap(appURL, with: staged)
    }

    /// Removes what an update that was interrupted (crash, power loss) left next to the app. Skipped
    /// while another Clipsody process installs an update in that folder.
    public static func removeLeftovers(besides appURL: URL) {
        let folder = appURL.deletingLastPathComponent()
        guard let lock = UpdateLock(for: folder) else { return }
        defer { lock.release() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static let stagingPrefix = ".Clipsody-Update-"

    private func installedVersion(at appURL: URL) -> SemanticVersion? {
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        return (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
    }

    /// Mounts the disk image read-only and without showing it, copies the app out and unmounts.
    private func copyApp(from diskImage: URL, mountingAt mount: URL, to staged: URL) throws {
        do {
            try fileManager.createDirectory(at: mount, withIntermediateDirectories: false)
            try runTool("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-quiet",
                                            "-mountpoint", mount.path, diskImage.path])
        } catch {
            throw Failure.noAppInDiskImage
        }
        defer { try? runTool("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let app = mount.appendingPathComponent("Clipsody.app")
        guard fileManager.fileExists(atPath: app.path) else { throw Failure.noAppInDiskImage }
        // ditto keeps the signature, extended attributes and symbolic links of the bundle intact.
        do {
            try runTool("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            throw Failure.noAppInDiskImage
        }
    }

    private func verify(_ app: URL, as release: UpdateCheck.Release) throws {
        guard let signature = readSignature(app),
              signature.certificateSHA256 == UpdateCheck.signingCertificateSHA256,
              signature.identifier == UpdateCheck.bundleIdentifier else { throw Failure.untrustedSignature }
        // Read after the seal is checked: Info.plist is part of it.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == UpdateCheck.bundleIdentifier,
              let version = (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
              version == release.version else { throw Failure.wrongVersion }
    }

    /// Exchanges the installed app and the staged one in a single step (same volume), so there is no
    /// moment without an app, also if Clipsody is killed right then. The old app ends up in the staging
    /// folder, which is deleted afterwards. If the exchange fails, nothing changed.
    private func swap(_ appURL: URL, with staged: URL) throws {
        guard renamex_np(staged.path, appURL.path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.replaceFailed }
    }

    public static let run: RunTool = { path, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(path) failed"])
        }
    }
}

/// An exclusive lock per app folder, held while an update is prepared and swapped in. It lives in the
/// user's temporary folder (not next to the app) and is released when the process ends, also on a crash.
final class UpdateLock: Sendable {
    private let descriptor: Int32

    /// Nil if another process holds the lock (or it cannot be created).
    init?(for folder: URL) {
        let name = "Clipsody-Update-" + ImageIngest.sha256(Data(folder.standardizedFileURL.path.utf8)).prefix(16) + ".lock"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Downloads release files: ephemeral session, HTTPS only, redirects only to GitHub's release asset
/// hosts, and a size limit.
public enum UpdateDownload {
    static let allowedHosts: Set = ["github.com", "release-assets.githubusercontent.com",
                                    "objects.githubusercontent.com"]

    static let session = UpdateChecker.makeSession(.ephemeral, delegate: AssetRedirects())

    public static let toFile: UpdateInstaller.Download = { url, destination, limit in
        try await toFile(url, destination: destination, limit: limit, using: session)
    }

    static func toFile(_ url: URL, destination: URL, limit: Int, using session: URLSession) async throws {
        guard allows(url) else { throw UpdateChecker.Failure.unreadableResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Clipsody", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else { throw UpdateChecker.Failure.unreadableResponse }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var total = 0
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            if total > limit { throw UpdateChecker.Failure.unreadableResponse }
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host else { return false }
        return allowedHosts.contains(host)
    }
}

/// GitHub answers a release download with a redirect to its asset host; nothing else is followed.
final class AssetRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        UpdateDownload.allows(request.url) ? request : nil
    }
}
