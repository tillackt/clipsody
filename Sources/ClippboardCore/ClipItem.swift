import Foundation

public struct ClipItem: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case text = 0
        case image = 1
        case files = 2
    }

    public let id: Int64
    public let kind: Kind
    /// Text items: the text. Files: the paths, one per line (for display and search). Images: empty.
    public let text: String
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
    public let recognizedText: String?
    /// Whether formatted text (RTF/HTML) was stored alongside the plain text.
    public let hasRichText: Bool
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
