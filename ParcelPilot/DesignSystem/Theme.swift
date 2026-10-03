import ParcelPilotKit
import SwiftUI
import UIKit

/// Design tokens (see DESIGN.md). Colours adapt to light/dark mode and all pairs meet WCAG AA for
/// text at the sizes used. Status is never conveyed by colour alone — always icon + text.
enum Theme {
    /// Light/dark colour. The provider closure must be nonisolated: SwiftUI and UIKit resolve dynamic
    /// colours on background render threads.
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = UIColor(hex: light), darkColor = UIColor(hex: dark)
        return Color(UIColor { @Sendable traits in traits.userInterfaceStyle == .dark ? darkColor : lightColor })
    }

    // Brand
    static let brand = dynamic(light: 0x1F5AE0, dark: 0x6E9BFF)
    static let teal = dynamic(light: 0x0B7A75, dark: 0x3CC8C1)
    static let brandSoft = dynamic(light: 0xE8EFFD, dark: 0x1B2A4A)

    // Semantic
    static let success = dynamic(light: 0x1A7F37, dark: 0x4CC163)
    static let danger = dynamic(light: 0xC62828, dark: 0xFF7B72)
    static let warning = dynamic(light: 0x9A5B00, dark: 0xF2B84B)
    static let neutral = dynamic(light: 0x5B6472, dark: 0xA3ACBA)
    static let demo = dynamic(light: 0x7A3FD1, dark: 0xC3A1FF)

    // Surfaces
    static let background = Color(UIColor.systemGroupedBackground)
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let elevated = Color(UIColor.systemBackground)
    static let separator = Color(UIColor.separator)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
    }

    /// Minimum interactive size (HIG): 44 pt. Primary delivery actions are taller.
    static let minTouch: CGFloat = 44
    static let primaryActionHeight: CGFloat = 56
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Address line on cards: large, semibold, scales with Dynamic Type.
    static let address = Font.title2.weight(.semibold)
    static let addressCompact = Font.headline
    static let unit = Font.title3.weight(.bold).monospacedDigit()
    static let metric = Font.headline.monospacedDigit()
}

// MARK: - Status semantics

enum StatusTone {
    case neutral, info, success, warning, danger, demo

    var color: Color {
        switch self {
        case .neutral: return Theme.neutral
        case .info: return Theme.brand
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .demo: return Theme.demo
        }
    }
}

extension AddressStatus {
    var tone: StatusTone {
        switch self {
        case .verified, .driverConfirmed: return .success
        case .pendingVerification, .needsReview: return .warning
        case .unresolvable: return .danger
        case .demoSynthetic: return .demo
        }
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .driverConfirmed: return "mappin.circle.fill"
        case .pendingVerification: return "icloud.slash"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .unresolvable: return "questionmark.circle.fill"
        case .demoSynthetic: return "theatermasks.fill"
        }
    }
}

extension StopStatus {
    var tone: StatusTone {
        switch self {
        case .pending: return .info
        case .partial: return .warning
        case .completed: return .success
        case .skipped: return .warning
        case .empty: return .neutral
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .partial: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle.fill"
        case .empty: return "circle.dashed"
        }
    }
}

extension PackageStatus {
    var tone: StatusTone {
        switch self {
        case .pending: return .info
        case .delivered: return .success
        case .failed: return .danger
        case .skipped: return .warning
        case .excluded: return .neutral
        }
    }
}

extension RecognitionLevel {
    var tone: StatusTone {
        switch self {
        case .high: return .success
        case .medium: return .warning
        case .low: return .danger
        }
    }
    var symbol: String {
        switch self {
        case .high: return "text.viewfinder"
        case .medium: return "text.magnifyingglass"
        case .low: return "eye.trianglebadge.exclamationmark"
        }
    }
}

extension MatchQuality {
    var tone: StatusTone {
        switch self {
        case .building, .driverPin: return .success
        case .buildingWithDifferences, .street: return .warning
        case .postalArea, .municipality, .conflict, .notFound: return .danger
        case .synthetic: return .demo
        }
    }
    var symbol: String {
        switch self {
        case .building: return "building.2.fill"
        case .buildingWithDifferences: return "building.2"
        case .street: return "road.lanes"
        case .postalArea: return "envelope.badge"
        case .municipality: return "map"
        case .conflict: return "exclamationmark.octagon"
        case .notFound: return "magnifyingglass"
        case .synthetic: return "theatermasks"
        case .driverPin: return "mappin"
        }
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
