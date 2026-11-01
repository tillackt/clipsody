import Foundation
import Testing
@testable import ClipsodyCore

@Suite struct SnippetStoreTests {
    let directory: TemporaryDirectory
    var file: URL { directory.url.appendingPathComponent("Clipsody Snippets/Snippets.json") }

    init() throws {
        directory = try TemporaryDirectory()
    }

    static let address = Snippet(name: "Meine Anschrift", fields: [
        .init(label: "Name", text: "Max Mustermann"), .init(label: "PLZ", text: "10115"), .init(label: "Ort", text: ""),
    ])

    @Test func savesPrivatelyAndLoadsAgain() throws {
        let store = SnippetStore(file: file)
        #expect(store.snippets.isEmpty)
        store.add(Self.address)
        var changed = Self.address
        changed.name = "Privat"
        store.update(changed)

        let reloaded = SnippetStore(file: file)
        #expect(reloaded.snippets == [changed])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        // Unlike the history, snippets belong in backups.
        let values = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup != true)

        reloaded.delete(id: changed.id)
        #expect(SnippetStore(file: file).snippets.isEmpty)
    }

    @Test func aDamagedFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = SnippetStore(file: file)
        #expect(store.snippets.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("Snippets.damaged-") })
        #expect(!names.contains("Snippets.json"))
    }

    @Test func aFileFromANewerVersionIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"format":"clipsody-snippets","version":2,"snippets":[]}"#.utf8)
        try newer.write(to: file)
        let store = SnippetStore(file: file)
        #expect(!store.canSave)
        store.add(Self.address)
        #expect(try Data(contentsOf: file) == newer)
    }

    @Test func anUnreadableFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A folder where the file should be: reading fails with something other than "no such file".
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let store = SnippetStore(file: file)
        #expect(!store.canSave)
        #expect(!store.save())
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test func ownSnippetsAreNeverCutOnLoad() throws {
        let long = String(repeating: "a", count: SnippetStore.maxTextLength + 10)
        let store = SnippetStore(file: file)
        store.add(Snippet(name: "Lang", fields: [.init(text: long)]))
        #expect(SnippetStore(file: file).snippets[0].fields[0].text.count == long.count)
    }

    @Test func importAddsWithoutChangingOrDuplicating() throws {
        let source = SnippetStore(file: directory.url.appendingPathComponent("a/Snippets.json"))
        source.add(Self.address)
        source.add(Snippet(name: "Signatur", fields: [.init(text: "Viele Grüße")]))
        let exported = source.exportData()

        let target = SnippetStore(file: file)
        // Same ID, different content: kept as it is; the imported one gets a new ID.
        target.add(Snippet(id: Self.address.id, name: "Eigene", fields: [.init(text: "x")]))
        #expect(try target.importData(exported) == 2)
        #expect(target.snippets.count == 3)
        #expect(target.snippets[0].name == "Eigene")
        #expect(Set(target.snippets.map(\.id)).count == 3)
        // Importing the same file again adds nothing.
        #expect(try target.importData(exported) == 0)
        #expect(SnippetStore(file: file).snippets.count == 3)
    }

    @Test func importRefusesOtherFiles() {
        let store = SnippetStore(file: file)
        #expect(throws: SnippetStore.Failure.unreadableFile) { try store.importData(Data("{}".utf8)) }
        #expect(throws: SnippetStore.Failure.unreadableFile) {
            try store.importData(Data(#"{"format":"other","version":1,"snippets":[]}"#.utf8))
        }
        #expect(throws: SnippetStore.Failure.unreadableFile) {
            try store.importData(Data(repeating: 0x20, count: SnippetStore.maxImportBytes + 1))
        }
        #expect(store.snippets.isEmpty)
    }

    @Test func importCutsOversizedContent() throws {
        let long = String(repeating: "a", count: SnippetStore.maxTextLength + 10)
        // One overlong text and too many fields, together still below the import size limit.
        let fields = [Snippet.Field(text: long)] + (0..<(SnippetStore.maxFields + 5)).map { Snippet.Field(text: "\($0)") }
        let source = SnippetStore(file: directory.url.appendingPathComponent("b/Snippets.json"))
        source.add(Snippet(name: "Groß", fields: fields))
        let store = SnippetStore(file: file)
        #expect(try store.importData(source.exportData()) == 1)
        #expect(store.snippets[0].fields.count == SnippetStore.maxFields)
        #expect(store.snippets[0].fields[0].text.count == SnippetStore.maxTextLength)
    }

    @Test func fieldsSearchAndKind() {
        #expect(Self.address.isSet)
        #expect(Self.address.filledFields.map(\.text) == ["Max Mustermann", "10115"])
        #expect(Self.address.searchText.contains("PLZ"))
        #expect(Self.address.searchText.contains("Meine Anschrift"))
        #expect(!Snippet(fields: [.init(text: "Gruß")]).isSet)
    }
}
