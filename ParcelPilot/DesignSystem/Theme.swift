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
    static let brand = dynamic(light: 0x4338CA, dark: 0x9C97FF)
    static let brandSoft = dynamic(light: 0xECEBFB, dark: 0x24233F)

    // Semantic
    static let success = dynamic(light: 0x177A3F, dark: 0x4CC97F)
    static let danger = dynamic(light: 0xB42318, dark: 0xFF7B72)
    static let warning = dynamic(light: 0x9A5700, dark: 0xF2B04B)
    static let neutral = dynamic(light: 0x5A606C, dark: 0xA4A9B2)
    static let demo = dynamic(light: 0x7A3FD1, dark: 0xC3A1FF)

    static let onBrand = dynamic(light: 0xFFFFFF, dark: 0x0E0F12)
    static let dangerSoft = dynamic(light: 0xFBE6E4, dark: 0x3A1E1E)
    static let warningSoft = dynamic(light: 0xFCF0DD, dark: 0x3A2E17)
    static let reviewPin = dynamic(light: 0xB36500, dark: 0xF2B04B)
    static let fill = dynamic(light: 0xF1F2F5, dark: 0x22252C)
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x17191E)
    static let hairline = Color(UIColor { traits in
        UIColor(hex: traits.accessibilityContrast == .high
            ? (traits.userInterfaceStyle == .dark ? 0x737986 : 0x858A95)
            : (traits.userInterfaceStyle == .dark ? 0x30343C : 0xE3E5EA))
    })
    static let ink = dynamic(light: 0x16181D, dark: 0xF2F3F5)
    static let pinPending = dynamic(light: 0x16181D, dark: 0xE6E8EC)
    static let background = dynamic(light: 0xF1F2F5, dark: 0x0E0F12)
    static let surface = panel
    static let elevated = panel
    static let separator = hairline

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
    static let primaryActionHeight: CGFloat = 58
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Address line on cards: large, semibold, scales with Dynamic Type.
    static let address = Font.system(.title, design: .rounded, weight: .bold)
    static let addressCompact = Font.headline
    static let unit = Font.system(.title, design: .monospaced, weight: .heavy)
    static let locationCode = Font.system(.title3, design: .monospaced, weight: .heavy)
    static let stopProgress = Font.system(.title3, design: .rounded, weight: .bold)
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
