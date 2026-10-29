import Foundation
import Testing
@testable import ClipsodyCore

/// Moving the data from the app's old name (Clippboard) to the new one (Clipsody).
@Suite struct LegacyDirectoryTests {
    let root: TemporaryDirectory
    var legacy: URL { root.url.appendingPathComponent("Clippboard") }
    var current: URL { root.url.appendingPathComponent("Clipsody") }

    init() throws {
        root = try TemporaryDirectory()
    }

    @Test func historyMovesToTheNewFolder() throws {
        let old = try Store(directory: legacy)
        _ = old.addText("kept across the rename", app: nil, appPath: nil)

        #expect(Store.adoptLegacyDirectory(legacy, into: current))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let moved = try Store(directory: current)
        #expect(moved.items().map(\.text) == ["kept across the rename"])
        withExtendedLifetime(old) {}
    }

    @Test func existingNewDataIsNeverOverwritten() throws {
        _ = try Store(directory: legacy)
        let newer = try Store(directory: current)
        _ = newer.addText("newer", app: nil, appPath: nil)

        #expect(!Store.adoptLegacyDirectory(legacy, into: current))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(newer.items().map(\.text) == ["newer"])
    }

    @Test func nothingToMoveWithoutOldFolder() {
        #expect(!Store.adoptLegacyDirectory(legacy, into: current))
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }
}
