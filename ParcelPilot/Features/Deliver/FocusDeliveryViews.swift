import ParcelPilotKit
import SwiftUI

struct DeliveryDestination: View {
    var stop: Stop
    var timeZone: TimeZone
    var collapsed: Bool = false
    var details: (() -> Void)? = nil
    var showMap: () -> Void = {}
    var showFullNotes = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = collapsed || typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                if let details {
                    Button(action: details) { addressText }
                        .buttonStyle(.row).accessibilityHint("Shows stop details")
                } else { addressText }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { unitAndMap }
                    VStack(alignment: .leading, spacing: 8) { unitAndMap }
                }
            }
            Text([stop.address.municipality, stop.address.postalCode].compactMap { $0 }.joined(separator: " "))
                .font(.subheadline).foregroundStyle(Theme.neutral)
            if let window = stop.timeWindow {
                Label(windowState(window), systemImage: "clock").font(.subheadline).foregroundStyle(Theme.brand)
                    .accessibilityHint(window.explanation)
            }
            if [.needsReview, .unresolvable, .pendingVerification].contains(stop.addressStatus) {
                StatusBadge(text: stop.addressStatus.label, symbol: stop.addressStatus.symbol, tone: stop.addressStatus.tone)
            }
            if !stop.notes.isEmpty {
                Label(stop.notes, systemImage: "note.text").font(.subheadline).lineLimit(showFullNotes ? nil : 1)
                    .accessibilityHint(showFullNotes ? "" : "Full note in stop details")
            }
        }
    }

    private var addressText: some View {
        Text(stop.address.streetLine ?? stop.address.singleLine)
            .font(.address).foregroundStyle(Theme.ink)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("nextStopAddress")
    }

    @ViewBuilder private var unitAndMap: some View {
        if let unit = stop.address.unit { UnitTile(value: unit).fixedSize(horizontal: true, vertical: false) }
        if collapsed {
            Button(action: showMap) { Label("Show map", systemImage: "map").lineLimit(1).fixedSize() }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("showMap")
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private func windowState(_ window: TimeWindowConstraint) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = Date()
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        if let start = window.startMinute, minute < start { return "opens \(WallClock.label(start))" }
        if minute > window.endMinute { return window.kind == .hard ? "window passed" : "preferred deadline passed" }
        return window.kind == .hard ? "open to \(WallClock.label(window.endMinute))" : "prefer by \(WallClock.label(window.endMinute))"
    }
}

struct PackageSelectionList: View {
    var packages: [Package]
    @Binding var deselected: Set<PackageID>
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let selected = packages.filter { !deselected.contains($0.id) }.count
        let tiles = packages.count <= 2 && !typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            Text("\(packages.count) PACKAGES · " + (selected == packages.count ? "IN YOUR VEHICLE" : "\(selected) SELECTED"))
                .font(.footnote.bold()).tracking(0.4).foregroundStyle(Theme.neutral)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            let layout = tiles ? AnyLayout(HStackLayout(alignment: .top, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                    Button {
                        if deselected.contains(package.id) { deselected.remove(package.id) } else { deselected.insert(package.id) }
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: deselected.contains(package.id) ? "square" : "checkmark.square.fill")
                                .font(.title2).foregroundStyle(Theme.brand).frame(minWidth: 44, minHeight: 44)
                            if !tiles { LocationCodeTile(location: package.storageLocation) }
                            VStack(alignment: .leading, spacing: 2) {
                                if tiles { Text(LocationCodeTile.code(for: package.storageLocation)).font(.locationCode) }
                                Text(package.storageLocation ?? "Location not set").font(.headline).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text([package.size?.label, package.trackingID.map { "••" + String($0.suffix(4)) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(Theme.neutral)
                                if !package.notes.isEmpty { Text(package.notes).font(.subheadline).foregroundStyle(Theme.neutral) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(tiles ? 8 : 4)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .background(tiles ? Theme.fill : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.row)
                    .accessibilityIdentifier("packageToggle.\(index)")
                    .accessibilityLabel("Include package \(package.trackingID.map { "ending " + String($0.suffix(4)) } ?? String(index + 1)), \(package.storageLocation ?? "location not set"), \(package.size?.label ?? "size not set")")
                    .accessibilityAddTraits(deselected.contains(package.id) ? [] : .isSelected)
                }
            }
        }
    }
}

struct ActionDeck: View {
    var destination: String
    var collapsed: Bool
    var selectedCount: Int
    var totalCount: Int
    var canNavigate: Bool
    var navigate: () -> Void
    var delivered: () -> Void
    var failed: () -> Void
    var skip: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var countLabel: String {
        selectedCount == totalCount ? "\(selectedCount) package\(selectedCount == 1 ? "" : "s")" : "\(selectedCount) of \(totalCount)"
    }
    private var navigateButton: some View {
        Button(action: navigate) { Label("Navigate", systemImage: "location").labelStyle(.titleAndIcon) }
            .buttonStyle(ActionButtonStyle(tint: Theme.brand, fill: Theme.brandSoft))
            .disabled(!canNavigate).accessibilityIdentifier("navigate")
    }
    private var otherActions: some View {
        Group {
            Button(action: failed) { Label("Failed", systemImage: "xmark.circle").labelStyle(.titleAndIcon) }
                .buttonStyle(ActionButtonStyle(tint: Theme.danger, fill: Theme.dangerSoft))
                .disabled(selectedCount == 0).accessibilityIdentifier("failed")
            Button(action: skip) { Label("Skip", systemImage: "arrow.uturn.forward").labelStyle(.titleAndIcon) }
                .buttonStyle(ActionButtonStyle()).accessibilityIdentifier("skip")
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            if collapsed {
                Text(destination).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityIdentifier("actionDestination")
            }
            VStack(spacing: 8) {
                if collapsed {
                    navigateButton
                    HStack(spacing: 8) { otherActions }
                } else {
                    HStack(spacing: 8) { navigateButton; otherActions }
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
            Button(action: delivered) {
                ViewThatFits(in: .horizontal) {
                    Label("Delivered · \(countLabel)", systemImage: "checkmark").fixedSize()
                    VStack(spacing: 2) { Label("Delivered", systemImage: "checkmark"); Text(countLabel) }
                }
                .font(.headline.bold()).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 72 : 58)
            }
            .buttonStyle(ActionButtonStyle(tint: Theme.onBrand, fill: Theme.success, height: typeSize.isAccessibilitySize ? 72 : 58, radius: 16))
            .disabled(selectedCount == 0)
            .accessibilityLabel("Delivered, \(selectedCount) of \(totalCount) packages")
            .accessibilityHint(selectedCount == 0 ? "Select a package" : "Records delivery for the selected packages")
            .accessibilityIdentifier("delivered")
            if selectedCount == 0 { Text("Select a package").font(.footnote).foregroundStyle(Theme.neutral) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.panel)
    }
}

struct StopStrip: View {
    var snapshot: RouteSnapshot
    @Binding var selectedStopID: StopID?
    var all: () -> Void
    var details: (StopID) -> Void
    @State private var callout: Stop?
    var body: some View {
        GeometryReader { geometry in
            let ordered = snapshot.orderedStops
            let current = ordered.firstIndex { $0.id == snapshot.nextStop()?.id } ?? 0
            let start = max(0, current - 2)
            let count = max(5, Int((geometry.size.height - 88) / 44))
            let end = min(ordered.count, max(current + 3, start + count))
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    Text("\(start + 1)–\(end)").font(.footnote.bold()).foregroundStyle(Theme.neutral)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(ordered[start..<end].enumerated()), id: \.element.id) { offset, stop in
                                Button { selectedStopID = stop.id; callout = stop } label: {
                                    StopBadge(number: start + offset + 1, state: .make(stop: stop, snapshot: snapshot, current: stop.id == snapshot.nextStop()?.id))
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Stop \(start + offset + 1), \(StopBadgeState.label(stop: stop, snapshot: snapshot)), \(stop.address.singleLine)")
                                .accessibilityIdentifier("stopStrip.\(start + offset + 1)")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Button(action: all) { VStack(spacing: 0) { Image(systemName: "list.bullet"); Text("All") }.font(.footnote.bold()).frame(width: 44, height: 44) }
                }
                .padding(4).frame(width: 52).background(Theme.panel, in: Capsule())
            }
            .padding(.vertical, 8)
            .popover(item: $callout) { stop in
                VStack(alignment: .leading, spacing: 12) {
                    Text([stop.address.streetLine ?? stop.address.singleLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                    Button("Details") { callout = nil; details(stop.id) }.frame(minHeight: 44)
                }.padding().presentationCompactAdaptation(.popover)
            }
        }
        .frame(width: 60)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("stopStrip")
    }
}

struct StopsSheet: View {
    var snapshot: RouteSnapshot
    var detail: (StopID) -> Void
    var replan: () -> Void
    var finish: () -> Void
    var backToPlanning: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var doneExpanded = false
    @State private var showSettings = false
    private var live: RouteSnapshot { services.store.current?.route.id == snapshot.route.id ? services.store.current! : snapshot }
    private func matches(_ stop: Stop) -> Bool {
        query.isEmpty || ([stop.address.singleLine] + live.packages(for: stop.id).flatMap { [$0.trackingID ?? "", $0.storageLocation ?? ""] } + live.tasks.filter { $0.stopID == stop.id }.map(\.title)).joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.neutral)
                    TextField("Address, unit, tracking or shelf", text: $query).autocorrectionDisabled()
                        .accessibilityIdentifier("stopsSearch")
                }.font(.subheadline).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(12).frame(minHeight: 44).background(Theme.fill, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16)
                if let toast = toasts.current {
                    UndoToast(message: toast.message, symbol: toast.symbol, tone: toast.tone,
                        undo: toasts.undoAction(for: toast),
                        extra: toast.extraTitle.flatMap { title in toast.extra.map { (title, $0) } }).padding(.vertical, 8)
                }
            List {
                Section {
                    let remaining = live.orderedStops.filter { [.pending, .partial, .skipped].contains(live.ledger.stopStatus($0, packages: live.packages)) }.count
                    VStack(alignment: .leading, spacing: 4) { Text("\(remaining) to do").font(.headline).dynamicTypeSize(...DynamicTypeSize.xxxLarge); StatusLine(snapshot: live) }
                }
                if query.isEmpty { Section { NeedsDecisionSection(snapshot: live, openWork: detail) } }
                if query.isEmpty {
                Section {
                    ForEach(Array(live.orderedStops.enumerated()).filter { matches($0.element) && [.pending, .partial].contains(live.ledger.stopStatus($0.element, packages: live.packages)) }, id: \.element.id) { index, stop in
                        stopRow(stop, index)
                    }
                } header: { Text("To do").font(.footnote.bold()).foregroundStyle(Theme.neutral).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                DisclosureGroup("Other stops & handled work", isExpanded: $doneExpanded) {
                    ForEach(Array(live.orderedStops.enumerated()).filter { matches($0.element) && ![.pending, .partial].contains(live.ledger.stopStatus($0.element, packages: live.packages)) }, id: \.element.id) { index, stop in stopRow(stop, index) }
                }
                }
                if !query.isEmpty {
                    Section("Search results") { ForEach(Array(live.orderedStops.enumerated()).filter { matches($0.element) }, id: \.element.id) { index, stop in stopRow(stop, index) } }
                }
            }
            .listStyle(.plain)
            }
            .navigationTitle("Stops").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: replan) { Label("Re-plan remaining", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.buttonStyle(SecondaryButtonStyle())
                    HStack {
                        Button("Finish route…", action: finish).frame(minHeight: 44).accessibilityIdentifier("finishRoute")
                        Spacer()
                        Menu {
                            Button("Route settings") { showSettings = true }
                            Button("All routes") { services.store.currentRouteID = nil; dismiss() }.accessibilityIdentifier("allRoutes")
                            Button("Back to planning", action: backToPlanning).accessibilityIdentifier("backToPlanning")
                        } label: { Label("Route options", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 44, height: 44) }.accessibilityIdentifier("routeMenu")
                    }
                }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(16).background(Theme.panel)
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showSettings) { RouteEditorView(route: live.route) }
    }
    private func stopRow(_ stop: Stop, _ index: Int) -> some View {
        Button { detail(stop.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                StopBadge(number: index + 1, state: .make(stop: stop, snapshot: live, current: stop.id == live.nextStop()?.id))
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    VStack(alignment: .leading) {
                        Text([stop.address.streetLine ?? stop.address.singleLine, stop.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.headline).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if live.ledger.stopStatus(stop, packages: live.packages) == .partial { Text(StopBadgeState.label(stop: stop, snapshot: live)).font(.subheadline).foregroundStyle(Theme.warning) }
                        if stop.id == live.nextStop()?.id { Text("NEXT").font(.footnote.bold()).foregroundStyle(Theme.brand).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Label("\(live.packages(for: stop.id).count)", systemImage: "shippingbox").font(.subheadline).foregroundStyle(Theme.neutral)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    let tasks = live.tasks.filter { $0.stopID == stop.id }
                    if !tasks.isEmpty {
                        Text("\(tasks.filter { $0.kind == .pickup }.count) pickups · \(tasks.filter { $0.kind == .checklist }.count) checklist items")
                            .font(.footnote).foregroundStyle(Theme.neutral).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(minHeight: 44)
        }.buttonStyle(.row).accessibilityIdentifier("stopRow.\(index + 1)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((["Stop \(index + 1)", stop.address.singleLine, "\(live.packages(for: stop.id).count) packages", "\(live.tasks.filter { $0.stopID == stop.id }.count) pickup/checklist items", StopBadgeState.label(stop: stop, snapshot: live), stop.id == live.nextStop()?.id ? "next stop" : nil, stop.timeWindow?.explanation].compactMap { $0 }).joined(separator: ", "))
    }
}
