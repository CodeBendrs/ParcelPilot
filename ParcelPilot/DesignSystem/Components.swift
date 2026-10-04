import ParcelPilotKit
import SwiftUI

/// Icon + text status chip. Colour reinforces, never replaces, the text.
struct StatusBadge: View {
    var text: String
    var symbol: String
    var tone: StatusTone
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 5)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Row button inside lists: keeps the row's own text colours (no tint) and dims while pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// Large, high-contrast action button used for delivery actions (thumb reach, 56 pt).
struct PrimaryActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.primaryActionHeight)
            .foregroundStyle(filled ? Color.white : tint)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(filled ? Color.clear : tint.opacity(0.5), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: Theme.minTouch)
            .padding(.horizontal, Theme.Space.m)
            .foregroundStyle(Theme.brand)
            .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Empty / error / permission / offline states always offer a next action.
struct StateMessageView: View {
    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var symbol: String?
        var role: ButtonRole?
        var handler: () -> Void
    }

    var symbol: String
    var title: String
    var message: String
    var actions: [Action] = []
    var tone: StatusTone = .neutral

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            ForEach(actions) { action in
                Button(role: action.role, action: action.handler) {
                    if let symbol = action.symbol { Label(action.title, systemImage: symbol) } else { Text(action.title) }
                }
                .buttonStyle(PrimaryActionButtonStyle(filled: action.id == actions.first?.id))
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 520)
    }
}

/// Inline banner for offline, configuration and warning messages.
struct Banner: View {
    var symbol: String
    var text: String
    var tone: StatusTone
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(tone.color).font(.body.weight(.semibold)).accessibilityHidden(true)
            // At accessibility sizes the action sits under the text instead of squeezing it.
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs)) : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.m))
            layout {
                Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize().frame(minHeight: Theme.minTouch)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Unit / apartment shown prominently so it is never lost behind a building address.
struct UnitBadge: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.unit)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(Theme.teal)
            .background(Theme.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(label.replacingOccurrences(of: "#", with: "Unit ")))
    }
}

/// Numbered stop marker used in lists (and mirrored on maps).
struct StopNumberView: View {
    var number: Int
    var status: StopStatus
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(status == .completed ? Theme.success : status == .skipped || status == .partial ? Theme.warning : Theme.brand)
            if status == .completed {
                Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.system(size: size * 0.42, weight: .bold).monospacedDigit()).foregroundStyle(.white).minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DemoBadge: View {
    var body: some View {
        StatusBadge(text: "Demo", symbol: "theatermasks.fill", tone: .demo, compact: true)
            .accessibilityLabel("Demo mode. Data stays on this iPhone and locations are synthetic.")
    }
}

/// Toast with an Undo action (delivery outcomes, batch adds). Stays long enough to reach.
struct UndoToast: View {
    var message: String
    var symbol: String
    var tone: StatusTone
    var undo: (() -> Void)?
    var extra: (title: String, action: () -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(tone.color).font(.title3).accessibilityHidden(true)
            Text(message).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            if let extra {
                Button(extra.title, action: extra.action).font(.subheadline.weight(.semibold)).frame(minHeight: Theme.minTouch)
            }
            if let undo {
                Button("Undo", action: undo)
                    .font(.subheadline.weight(.bold))
                    .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                    .accessibilityHint("Reverses the last action")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, Theme.Space.l)
        .accessibilityElement(children: .contain)
    }
}

/// A small "source" caption used wherever estimates are shown (honest provenance + calculation time).
struct ProvenanceText: View {
    var text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Card container for grouped content.
    func card() -> some View {
        padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
    }
}

/// Toast state with automatic dismissal.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var symbol: String
        var tone: StatusTone
        var undo: (() -> Void)?
        var extraTitle: String?
        var extra: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, symbol: String, tone: StatusTone, undo: (() -> Void)? = nil, extraTitle: String? = nil, extra: (() -> Void)? = nil, seconds: Double = 8) {
        current = Toast(message: message, symbol: symbol, tone: tone, undo: undo, extraTitle: extraTitle, extra: extra)
        UIAccessibility.post(notification: .announcement, argument: message)
        dismissTask?.cancel()
        let id = current!.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.current?.id == id { self?.current = nil }
        }
    }

    func dismiss() { current = nil }
}

struct ToastOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var center: ToastCenter

    func body(content: Content) -> some View {
        // Top of the tab's safe area: never covers the tab bar or the pinned delivery actions.
        content.overlay(alignment: .top) {
            if let toast = center.current {
                UndoToast(
                    message: toast.message, symbol: toast.symbol, tone: toast.tone,
                    undo: toast.undo.map { undo in { undo(); center.dismiss() } },
                    extra: toast.extraTitle.flatMap { title in toast.extra.map { (title, $0) } }
                )
                .padding(.top, Theme.Space.s)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: center.current)
    }
}

extension View {
    func toasts(_ center: ToastCenter) -> some View { modifier(ToastOverlay(center: center)) }
}

/// Shows content as is when it fits vertically, otherwise inside a scroll view (large text sizes on
/// small screens) so nothing is truncated or clipped.
struct FitOrScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView { content().frame(maxWidth: .infinity) }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}
