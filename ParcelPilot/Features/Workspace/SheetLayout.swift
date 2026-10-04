import SwiftUI

enum SheetDetent: Int, CaseIterable {
    case collapsed, medium, expanded

    var label: String {
        switch self {
        case .collapsed: return "collapsed"
        case .medium: return "half height"
        case .expanded: return "full height"
        }
    }
}

/// Map above, draggable panel below. The map is laid out above the panel and receives the small
/// corner overlap as its bottom inset, so markers and the provider's attribution stay visible.
struct MapSheetLayout<MapContent: View, SheetContent: View>: View {
    @Binding var detent: SheetDetent
    var collapsedHeight: CGFloat = 230
    /// Share of the height the panel takes at the half-height detent. Short screens (iPhone SE) get
    /// a little more so panel content isn't squeezed under its pinned controls.
    var mediumFraction: CGFloat = 0.70
    var allowsCollapse = true
    @ViewBuilder var map: (_ bottomInset: CGFloat) -> MapContent
    @ViewBuilder var sheet: () -> SheetContent

    @GestureState private var drag: CGFloat = 0
    private let cornerOverlap: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height
            let heights: [SheetDetent: CGFloat] = [
                .collapsed: min(collapsedHeight, full * 0.45),
                .medium: full * min(mediumFraction + (full < 620 ? 0.08 : 0), 0.8),
                .expanded: full * 0.92,
            ]
            let availableHeights = heights.filter { allowsCollapse || $0.key != .collapsed }
            let base = heights[detent] ?? full * 0.5
            let minimumHeight = allowsCollapse ? heights[.collapsed]! * 0.8 : heights[.medium]!
            let height = min(max(base - drag, minimumHeight), full)
            ZStack(alignment: .bottom) {
                // The map occupies only the area above the panel (plus the panel's rounded corner
                // overlap), so map framing and the provider's attribution stay visible.
                map(cornerOverlap)
                    .frame(height: max(full - height + cornerOverlap, cornerOverlap * 2))
                    .frame(maxHeight: .infinity, alignment: .top)
                VStack(spacing: 0) {
                    handle(heights: availableHeights)
                    sheet()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(height: height)
                .background(Theme.elevated)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.xl, topTrailingRadius: Theme.Radius.xl, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: detent)
            .onChange(of: full, initial: true) { _, height in
                if height > 0 && height < 620 && detent == .medium { detent = .expanded }
            }
        }
    }

    private func handle(heights: [SheetDetent: CGFloat]) -> some View {
        Button {
            detent = detent == .expanded ? (allowsCollapse ? .collapsed : .medium) : .expanded
        } label: {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        let target = (heights[detent] ?? 0) - value.predictedEndTranslation.height
                        detent = heights.min { abs($0.value - target) < abs($1.value - target) }?.key ?? detent
                    }
            )
            .accessibilityIdentifier("panelHandle")
            .accessibilityHint("Tap or drag to resize the stop list")
            .accessibilityLabel("Stop list panel, \(detent.label)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Expand") { detent = .expanded }
            .accessibilityAction(named: "Half height") { detent = .medium }
            .accessibilityAction(named: "Collapse") { detent = allowsCollapse ? .collapsed : .medium }
    }
}
