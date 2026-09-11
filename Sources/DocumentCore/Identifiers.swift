import Foundation

/// A typed, stable identifier backed by a UUID. Every persisted entity has one.
/// Identifiers are encoded as their canonical uppercase UUID string.
public protocol EntityIdentifier: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

extension EntityIdentifier {
    public init() { self.init(rawValue: UUID()) }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid identifier '\(string)'")
        }
        self.init(rawValue: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct DocumentID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct PageID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ObjectID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct AssetID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct RevisionID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct FolderID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct ReviewItemID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct InkLayerID: EntityIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
