import SwiftUI

/// Fixed header / flexible map / fixed bottom. Measure the uncollapsed content independently,
/// so a short stop or a smaller text setting can restore the map after a longer stop collapsed it.
struct FocusLayout<Header: View, MapContent: View, Bottom: View, Actions: View>: View {
    @ViewBuilder var header: (Bool) -> Header
    @ViewBuilder var map: () -> MapContent
    @ViewBuilder var bottom: () -> Bottom
    @ViewBuilder var actions: (Bool) -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var fixedHeight: CGFloat = 460

    var body: some View {
        GeometryReader { geometry in
            let mapCollapsed = typeSize.isAccessibilitySize || geometry.size.height - fixedHeight < 160
            VStack(spacing: 0) {
                if mapCollapsed {
                    ScrollView {
                        VStack(spacing: 0) {
                            header(true).accessibilitySortPriority(4)
                            bottom().accessibilitySortPriority(3)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilitySortPriority(4)
                } else {
                    header(false).fixedSize(horizontal: false, vertical: true).accessibilitySortPriority(4)
                    map().frame(maxHeight: .infinity).accessibilitySortPriority(0)
                    bottom().fixedSize(horizontal: false, vertical: true).accessibilitySortPriority(3)
                }
                actions(mapCollapsed).fixedSize(horizontal: false, vertical: true).accessibilitySortPriority(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
            .background(alignment: .top) {
                VStack(spacing: 0) { header(false); bottom(); actions(false) }
                    .frame(width: geometry.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fixedHeight = $0 }
                    .hidden().accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }
}
