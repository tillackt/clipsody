import ClipsodyCore
import Foundation
import Testing
@testable import ClipsodyServices

/// The installer with the network, hdiutil, ditto and Security.framework replaced: what it installs,
/// and that it leaves the installed app alone whenever a check fails.
@Suite struct UpdateInstallerTests {
    let directory: TemporaryDirectory
    let appURL: URL
    let release = UpdateCheck.Release(version: SemanticVersion("1.4.0")!)
    static let diskImage = Data("disk image".utf8)
    static let trusted = UpdateSignature(certificateSHA256: UpdateCheck.signingCertificateSHA256,
                                         identifier: UpdateCheck.bundleIdentifier)
    static let trustedImage = UpdateSignature(certificateSHA256: UpdateCheck.signingCertificateSHA256,
                                              identifier: UpdateCheck.bundleIdentifier + ".dmg")

    init() throws {
        directory = try TemporaryDirectory()
        appURL = directory.url.appendingPathComponent("Applications/Clipsody.app")
        try Self.makeApp(at: appURL, version: "1.3.0", marker: "old")
    }

    static func makeApp(at url: URL, version: String, marker: String,
                        identifier: String = UpdateCheck.bundleIdentifier) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
    }

    func marker() -> String? {
        (try? Data(contentsOf: appURL.appendingPathComponent("Contents/marker"))).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Serves the disk image and a checksum file (of `checksumOf`, normally the image itself).
    static func download(checksumOf data: Data = diskImage) -> UpdateInstaller.Download {
        { url, destination, _ in
            let body = url.lastPathComponent.hasSuffix(".sha256")
                ? Data("\(ImageIngest.sha256(data))  Clipsody.dmg\n".utf8) : diskImage
            try body.write(to: destination)
        }
    }

    /// "Mounts" by creating the app in the mount point; ditto copies it.
    static func tools(version: String = "1.4.0", identifier: String = UpdateCheck.bundleIdentifier,
                      withApp: Bool = true) -> UpdateInstaller.RunTool {
        { path, arguments in
            switch (path, arguments.first) {
            case ("/usr/bin/hdiutil", "attach"?):
                guard withApp, let index = arguments.firstIndex(of: "-mountpoint") else { return }
                try makeApp(at: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("Clipsody.app"),
                            version: version, marker: "new", identifier: identifier)
            case ("/usr/bin/ditto", _):
                try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
            default: break
            }
        }
    }

    /// The disk image gets `image`, everything else (the staged app) `signature`.
    static func signatures(app signature: UpdateSignature?, image: UpdateSignature? = trustedImage,
                           checked: URLRecorder? = nil) -> UpdateInstaller.ReadSignature {
        { url in
            checked?.add(url)
            return url.pathExtension == "dmg" ? image : signature
        }
    }

    func install(download: @escaping UpdateInstaller.Download = download(),
                 tools: @escaping UpdateInstaller.RunTool = tools(),
                 signature: UpdateSignature? = trusted, image: UpdateSignature? = trustedImage,
                 currentVersion: String = "1.3.0") async throws {
        let installer = UpdateInstaller(download: download, runTool: tools,
                                        readSignature: Self.signatures(app: signature, image: image))
        try await installer.install(release, currentVersion: currentVersion, replacing: appURL)
    }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: appURL.deletingLastPathComponent().path)
    }

    @Test func installsATrustedNewerVersionAndCleansUp() async throws {
        let steps = StepRecorder()
        let checked = URLRecorder()
        let detached = URLRecorder()
        let tools = Self.tools()
        let installer = UpdateInstaller(download: Self.download(), runTool: { path, arguments in
            if arguments.first == "detach" { detached.add(URL(fileURLWithPath: arguments.last ?? "")) }
            try tools(path, arguments)
        }, readSignature: Self.signatures(app: Self.trusted, checked: checked))
        try await installer.install(release, currentVersion: "1.3.0", replacing: appURL) { steps.add($0) }
        #expect(marker() == "new")
        #expect(try leftovers() == ["Clipsody.app"])
        #expect(steps.all == [.downloading, .verifying, .installing])
        // First the disk image, then the copy that is installed (not the mounted original).
        #expect(checked.all.map(\.lastPathComponent) == ["Clipsody.dmg", "Clipsody.app"])
        #expect(checked.all.last?.deletingLastPathComponent().lastPathComponent.hasPrefix(".Clipsody-Update-") == true)
        #expect(detached.all.count == 1)
    }

    @Test func refusesADiskImageNotSignedForRelease() async throws {
        let other = UpdateSignature(certificateSHA256: String(repeating: "1", count: 64),
                                    identifier: UpdateCheck.bundleIdentifier + ".dmg")
        let mounted = URLRecorder()
        let tools = Self.tools()
        await #expect(throws: UpdateInstaller.Failure.untrustedSignature) {
            try await install(tools: { path, arguments in
                if arguments.first == "attach" { mounted.add(URL(fileURLWithPath: path)) }
                try tools(path, arguments)
            }, image: other)
        }
        // Rejected before hdiutil ever reads it.
        #expect(mounted.all.isEmpty)
        #expect(marker() == "old")
    }

    @Test func doesNotReplaceANewerInstallationThatAppearedMeanwhile() async throws {
        let tools = Self.tools()
        let appURL = appURL
        await #expect(throws: UpdateInstaller.Failure.wrongVersion) {
            try await install(tools: { path, arguments in
                try tools(path, arguments)
                // Another installer puts 1.5.0 in place while this one prepares 1.4.0.
                if path == "/usr/bin/ditto" {
                    try FileManager.default.removeItem(at: appURL)
                    try Self.makeApp(at: appURL, version: "1.5.0", marker: "newer")
                }
            })
        }
        #expect(marker() == "newer")
        #expect(try leftovers() == ["Clipsody.app"])
    }

    @Test func refusesADestinationWithoutAReadableVersion() async throws {
        try FileManager.default.removeItem(at: appURL.appendingPathComponent("Contents/Info.plist"))
        await #expect(throws: UpdateInstaller.Failure.wrongVersion) { try await install() }
        #expect(marker() == "old")
        #expect(try leftovers() == ["Clipsody.app"])
    }

    @Test func oneUpdateAtATimeAndNoCleanUpDuringIt() async throws {
        let folder = appURL.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".Clipsody-Update-busy")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        // Another process (here: a lock held in this one) is installing into the same folder.
        let held = try #require(UpdateLock(for: folder))
        await #expect(throws: UpdateInstaller.Failure.replaceFailed) { try await install() }
        UpdateInstaller.removeLeftovers(besides: appURL)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        held.release()
        UpdateInstaller.removeLeftovers(besides: appURL)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(marker() == "old")
    }

    @Test func removesLeftoversOfAnInterruptedUpdate() throws {
        let folder = appURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".Clipsody-Update-crashed/Clipsody.app"),
                                                withIntermediateDirectories: true)
        UpdateInstaller.removeLeftovers(besides: appURL)
        #expect(try leftovers() == ["Clipsody.app"])
        #expect(marker() == "old")
    }

    @Test func refusesAnotherCertificate() async throws {
        let other = UpdateSignature(certificateSHA256: String(repeating: "0", count: 64),
                                    identifier: UpdateCheck.bundleIdentifier)
        await #expect(throws: UpdateInstaller.Failure.untrustedSignature) { try await install(signature: other) }
        #expect(marker() == "old")
        #expect(try leftovers() == ["Clipsody.app"])
    }

    @Test func refusesUnsignedOrBrokenSeals() async throws {
        await #expect(throws: UpdateInstaller.Failure.untrustedSignature) { try await install(signature: nil) }
        let adHoc = UpdateSignature(certificateSHA256: nil, identifier: UpdateCheck.bundleIdentifier)
        await #expect(throws: UpdateInstaller.Failure.untrustedSignature) { try await install(signature: adHoc) }
        #expect(marker() == "old")
    }

    @Test func refusesAnotherAppOrIdentifier() async throws {
        let foreign = UpdateSignature(certificateSHA256: UpdateCheck.signingCertificateSHA256, identifier: "com.example")
        await #expect(throws: UpdateInstaller.Failure.untrustedSignature) { try await install(signature: foreign) }
        await #expect(throws: UpdateInstaller.Failure.wrongVersion) {
            try await install(tools: Self.tools(identifier: "com.example"))
        }
        #expect(marker() == "old")
    }

    @Test func refusesAVersionOtherThanAnnounced() async throws {
        // An older (or simply different) app in the disk image would be a downgrade.
        await #expect(throws: UpdateInstaller.Failure.wrongVersion) { try await install(tools: Self.tools(version: "1.2.0")) }
        // Nothing is downloaded for a release that is not newer than the running app.
        await #expect(throws: UpdateInstaller.Failure.wrongVersion) { try await install(currentVersion: "1.4.0") }
        #expect(marker() == "old")
    }

    @Test func refusesAChecksumMismatch() async throws {
        await #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
            try await install(download: Self.download(checksumOf: Data("something else".utf8)))
        }
        #expect(marker() == "old")
        #expect(try leftovers() == ["Clipsody.app"])
    }

    @Test func reportsDownloadFailuresAndMissingApps() async throws {
        await #expect(throws: UpdateInstaller.Failure.download) {
            try await install(download: { _, _, _ in throw URLError(.notConnectedToInternet) })
        }
        await #expect(throws: UpdateInstaller.Failure.noAppInDiskImage) { try await install(tools: Self.tools(withApp: false)) }
        #expect(marker() == "old")
    }

    @Test func refusesAFolderItCannotWrite() async throws {
        let folder = appURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await #expect(throws: UpdateInstaller.Failure.notWritable) { try await install() }
        #expect(marker() == "old")
    }
}

/// Collects URLs across threads.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// Collects the reported steps across threads.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [UpdateInstaller.Step] = []

    func add(_ step: UpdateInstaller.Step) {
        lock.lock()
        steps.append(step)
        lock.unlock()
    }

    var all: [UpdateInstaller.Step] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

@Suite struct UpdateSignatureTests {
    @Test func unsignedFilesHaveNoSignature() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        #expect(UpdateSignature.read(at: file) == nil)
    }

    @Test func appleSignedCodeIsNotTheReleaseCertificate() throws {
        let signature = try #require(UpdateSignature.read(at: URL(fileURLWithPath: "/usr/bin/true")))
        #expect(signature.certificateSHA256 != nil)
        #expect(signature.certificateSHA256 != UpdateCheck.signingCertificateSHA256)
    }

    @Test func aModifiedSignedBinaryFailsTheSealCheck() throws {
        let directory = try TemporaryDirectory()
        let copy = directory.url.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        #expect(UpdateSignature.read(at: copy) != nil)
        // Change one byte of the code; the signature is still there, but the seal no longer matches.
        var bytes = try Data(contentsOf: copy)
        let index = bytes.count / 2
        bytes[index] ^= 0xFF
        try bytes.write(to: copy)
        #expect(UpdateSignature.read(at: copy) == nil)
    }

    @Test func downloadsOnlyFromGitHubOverHTTPS() {
        #expect(UpdateDownload.allows(URL(string: "https://github.com/tillackt/clipsody/releases/download/v1/Clipsody.dmg")))
        #expect(UpdateDownload.allows(URL(string: "https://release-assets.githubusercontent.com/x")))
        #expect(!UpdateDownload.allows(URL(string: "http://github.com/x")))
        #expect(!UpdateDownload.allows(URL(string: "https://example.com/Clipsody.dmg")))
        #expect(!UpdateDownload.allows(URL(string: "https://github.com.example.com/x")))
    }

    @Test func checksumFilesAreParsedStrictly() {
        let hash = String(repeating: "aB", count: 32)
        #expect(UpdateCheck.checksum(fromFile: Data("\(hash)  Clipsody.dmg\n".utf8)) == hash.lowercased())
        #expect(UpdateCheck.checksum(fromFile: Data("abc  Clipsody.dmg".utf8)) == nil)
        #expect(UpdateCheck.checksum(fromFile: Data(repeating: 0x61, count: 2_000)) == nil)
    }

    @Test func releaseFilesBelongToTheAnnouncedVersion() {
        let release = UpdateCheck.Release(version: SemanticVersion("1.4.0")!)
        #expect(release.diskImageURL.absoluteString.hasSuffix("/releases/download/v1.4.0/Clipsody.dmg"))
        #expect(release.checksumURL.absoluteString.hasSuffix("/releases/download/v1.4.0/Clipsody.dmg.sha256"))
    }
}
