import Foundation

public struct ClipItem: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case text = 0
        case image = 1
        case files = 2
    }

    public let id: Int64
    public let kind: Kind
    /// Text items: the beginning of the text (see `Store.listTextPrefix`; `Store.fullText` has all
    /// of it). Files: the paths, one per line (for display and search). Images: empty.
    public var text: String
    /// Size of the complete text in bytes, also when `text` holds only its beginning.
    public let textByteCount: Int
    public let filePaths: [String]
    public let imageFile: String?
    public let imageWidth: Int
    public let imageHeight: Int
    /// Size of the stored image file in bytes (0 for other kinds).
    public let byteSize: Int64
    public let app: String?
    public let appPath: String?
    public let date: Date
    public let pinned: Bool
    /// Text recognised in an image; nil until recognition ran.
    public var recognizedText: String?
    /// Whether formatted text (RTF/HTML) was stored alongside the plain text.
    public let hasRichText: Bool

    public init(id: Int64, kind: Kind, text: String, textByteCount: Int? = nil, filePaths: [String] = [],
                imageFile: String? = nil, imageWidth: Int = 0, imageHeight: Int = 0, byteSize: Int64 = 0,
                app: String? = nil, appPath: String? = nil, date: Date, pinned: Bool = false,
                recognizedText: String? = nil, hasRichText: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.textByteCount = textByteCount ?? text.utf8.count
        self.filePaths = filePaths
        self.imageFile = imageFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteSize = byteSize
        self.app = app
        self.appPath = appPath
        self.date = date
        self.pinned = pinned
        self.recognizedText = recognizedText
        self.hasRichText = hasRichText
    }
}

/// Formatted text as it came from the pasteboard; `type` is the UTI (public.rtf, public.html).
public struct RichText: Equatable, Sendable {
    public let data: Data
    public let type: String

    public init(data: Data, type: String) {
        self.data = data
        self.type = type
    }
}

/// Limits for what is recorded from the clipboard.
public enum CaptureLimits {
    /// Plain text above this size (e.g. a huge log) is not stored.
    public static let maxTextBytes = 2_000_000
    /// Formatting above this size is dropped; the plain text is still stored.
    public static let maxRichTextBytes = 1_000_000
}
