import Foundation

/// A text snippet the user writes and names: one text (a signature, a standard reply) or several
/// fields that fill a form (name, street, postcode, city).
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        /// Optional, e.g. "Postcode"; shown in the fill bar next to the text.
        public var label: String
        public var text: String

        public init(label: String = "", text: String = "") {
            self.label = label
            self.text = text
        }
    }

    public let id: UUID
    public var name: String
    public var fields: [Field]

    public init(id: UUID = UUID(), name: String = "", fields: [Field] = [Field()]) {
        self.id = id
        self.name = name
        self.fields = fields
    }

    /// Several fields open the fill bar; a single text is pasted directly.
    public var isSet: Bool { fields.count > 1 }

    /// Fields that have a text; empty ones are left out when pasting.
    public var filledFields: [Field] { fields.filter { !$0.text.isEmpty } }

    /// What a search looks through: the name, the labels and the texts.
    public var searchText: String {
        ([name] + fields.flatMap { [$0.label, $0.text] }).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The snippets, kept in their own file outside the history folder: unlike the history, which is
/// excluded from backups on purpose, written snippets must survive in Time Machine. The file is
/// readable only by the user (folder 0700, file 0600) and written atomically.
public final class SnippetStore {
    public enum Failure: Error, Equatable {
        case unreadableFile
    }

    public private(set) var snippets: [Snippet]
    public let file: URL
    /// False if the file exists but could not be read: then nothing is written, so it is never
    /// replaced by an empty or partial list.
    public private(set) var canSave = true
    /// Whether the last save worked; the editor warns otherwise.
    public private(set) var lastSaveSucceeded = true

    /// Limits for files to import; far beyond what anyone types by hand.
    static let maxImportBytes = 5 * 1024 * 1024
    static let maxSnippets = 1_000
    static let maxFields = 100
    static let maxTextLength = 100_000

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipsody Snippets/Snippets.json")
    }

    /// The folder the snippets live in; the uninstaller removes it.
    public var directory: URL { file.deletingLastPathComponent() }

    /// Loads the snippets. A missing file means none yet. A file that cannot be read, or comes from a
    /// newer Clipsody, is left alone and nothing is saved; a damaged one is moved aside first.
    public init(file: URL = SnippetStore.defaultFile) {
        self.file = file
        snippets = []
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            logger.error("Snippets file could not be read; not saving to protect it")
            canSave = false
            return
        }
        switch Self.parse(data) {
        case .snippets(let loaded):
            snippets = loaded
        case .newerVersion:
            logger.error("Snippets file is from a newer Clipsody; not saving to protect it")
            canSave = false
        case .damaged:
            let aside = file.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            if (try? FileManager.default.moveItem(at: file, to: aside)) == nil { canSave = false }
            logger.error("Snippets file is damaged; moved aside")
        }
    }

    // MARK: - Changes

    @discardableResult
    public func add(_ snippet: Snippet = Snippet()) -> Snippet {
        snippets.append(snippet)
        save()
        return snippet
    }

    public func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    public func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    /// Writes the file now; returns false (and logs) if that failed.
    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ownerOnly)
            try exportData().write(to: file, options: [.atomic])
            FilePermissions.set(0o600, of: file)
            lastSaveSucceeded = true
        } catch {
            logger.error("Snippets could not be saved: \(String(describing: error), privacy: .public)")
            lastSaveSucceeded = false
        }
        return lastSaveSucceeded
    }

    // MARK: - Export and import

    /// A readable JSON file with all snippets.
    public func exportData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and UUIDs cannot fail.
        return (try? encoder.encode(ExportFile(snippets: snippets))) ?? Data()
    }

    /// Adds the snippets of an exported file; nothing existing is changed. Snippets that already
    /// exist with the same name and fields are skipped; a clashing ID gets a new one. Returns how
    /// many were added.
    public func importData(_ data: Data) throws -> Int {
        guard data.count <= Self.maxImportBytes, case .snippets(let parsed) = Self.parse(data) else {
            throw Failure.unreadableFile
        }
        let incoming = Self.limited(parsed)
        var added = 0
        for snippet in incoming where snippets.count < Self.maxSnippets {
            guard !snippets.contains(where: { $0.name == snippet.name && $0.fields == snippet.fields }) else { continue }
            let id = snippets.contains { $0.id == snippet.id } ? UUID() : snippet.id
            snippets.append(Snippet(id: id, name: snippet.name, fields: snippet.fields))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    enum Parsed {
        case snippets([Snippet]), newerVersion, damaged
    }

    static func parse(_ data: Data) -> Parsed {
        guard let file = try? JSONDecoder().decode(ExportFile.self, from: data), file.format == ExportFile.formatName
        else { return .damaged }
        return file.version == 1 ? .snippets(file.snippets) : (file.version > 1 ? .newerVersion : .damaged)
    }

    /// Imported files beyond these sizes are not of ours: cut rather than refuse the whole file. The
    /// user's own file is never cut.
    static func limited(_ snippets: [Snippet]) -> [Snippet] {
        snippets.prefix(maxSnippets).map { snippet in
            Snippet(id: snippet.id, name: String(snippet.name.prefix(1_000)),
                    fields: snippet.fields.prefix(maxFields).map {
                        Snippet.Field(label: String($0.label.prefix(1_000)), text: String($0.text.prefix(maxTextLength)))
                    })
        }.filter { !$0.fields.isEmpty }
    }
}

/// The file format: also what export writes, so a backup copy of Snippets.json can be imported.
private struct ExportFile: Codable {
    static let formatName = "clipsody-snippets"
    var format = formatName
    var version = 1
    var snippets: [Snippet]
}
