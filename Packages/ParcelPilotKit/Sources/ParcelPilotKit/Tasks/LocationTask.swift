import Foundation

/// Unknown future kinds remain visible instead of making required work disappear during decoding.
public struct WorkKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let delivery = Self(rawValue: "delivery")
    public static let pickup = Self(rawValue: "pickup")
    public static let checklist = Self(rawValue: "checklist")
    public var isSupported: Bool { self == .delivery || self == .pickup || self == .checklist }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// Only pickup/checklist definitions are persisted. Delivery work is a lightweight identity
/// projection of Package; package details and delivery outcomes are never copied into task records.
public struct LocationTask: Codable, Hashable, Sendable, Identifiable {
    public var id: TaskID
    public var schemaVersion: Int
    public var stopID: StopID
    public var kind: WorkKind
    public var required: Bool
    public var title: String
    public var instructions: String
    public var orderRank: Int
    public var packageID: PackageID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: TaskID = StableID.make(), stopID: StopID, kind: WorkKind, required: Bool = true, title: String = "", instructions: String = "", orderRank: Int = 0, packageID: PackageID? = nil, now: Date = Date()) {
        self.id = id; self.schemaVersion = 1; self.stopID = stopID; self.kind = kind
        self.required = required; self.title = title; self.instructions = instructions
        self.orderRank = orderRank; self.packageID = packageID; self.createdAt = now; self.updatedAt = now
    }

    public static func deliveryID(for packageID: PackageID) -> TaskID { "delivery_" + packageID }
    public static func projection(for package: Package) -> Self {
        Self(id: deliveryID(for: package.id), stopID: package.stopID, kind: .delivery,
             packageID: package.id, now: package.createdAt)
    }
}

public enum WorkState: Hashable, Sendable {
    case pending
    case completed(at: Date)
    case failed(FailureReason?, at: Date)
    case deferred(at: Date)
    case excluded(at: Date)
    /// Unsupported definitions, invalid targeting or conflicting event identities require review.
    case unsupported

    public var isHandled: Bool {
        switch self { case .completed, .failed, .excluded: true; default: false }
    }
    public var isSuccessful: Bool { if case .completed = self { true } else { false } }
    public var isActionable: Bool { self == .pending }
}

/// State counters refer to required work only. Optional work is separately counted and never
/// inflates outstanding work or successful completion.
public struct WorkSummary: Codable, Hashable, Sendable {
    public var required = 0
    public var optional = 0
    public var completed = 0
    public var failed = 0
    public var deferred = 0
    public var excluded = 0
    public var pending = 0
    public var unsupported = 0
    public init() {}
    public var outstanding: Int { pending + deferred + unsupported }
    public var handled: Int { completed + failed + excluded }
    public var isHandled: Bool { outstanding == 0 }
}
