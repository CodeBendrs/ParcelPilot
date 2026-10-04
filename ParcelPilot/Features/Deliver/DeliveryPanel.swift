import ParcelPilotKit
import SwiftUI

struct DeliveryPanel: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    @Binding var sheet: WorkspaceSheet?
    @Binding var selectedStopID: StopID?

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase
    @State private var outcomeSheet: OutcomeSheet?
    @State private var choosingNavApp: Stop?
    @State private var photoFor: PhotoTarget?
    @State private var navError: String?
    @State private var confirmFinish = false
    @State private var returnedFromNavigation: StopID?

    enum OutcomeSheet: Identifiable {
        case packages(Stop, OutcomeKind)
        case failure(Stop, [PackageID])
        var id: String {
            switch self {
            case let .packages(s, k): return "pk-\(s.id)-\(k.rawValue)"
            case let .failure(s, _): return "fail-\(s.id)"
            }
        }
    }

    struct PhotoTarget: Identifiable { var stopID: StopID; var packageIDs: [PackageID]; var id: String { stopID } }

    var body: some View {
        let ledger = snapshot.ledger
        let ordered = snapshot.orderedStops
        let next = snapshot.nextStop()
        let summary = snapshot.summary()
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ProgressHeader(summary: summary)
                    if let id = returnedFromNavigation, let stop = snapshot.stops.first(where: { $0.id == id }), ledger.stopStatus(stop, packages: snapshot.packages) != .completed {
                        Banner(symbol: "arrow.uturn.backward.circle", text: "Back from navigation. Record what happened at \(stop.address.streetLine ?? "this stop") — nothing was marked automatically.", tone: .info)
                            .accessibilityIdentifier("returnBanner")
                    }
                    if let next {
                        let number = (ordered.firstIndex(where: { $0.id == next.id }) ?? 0) + 1
                        NextStopInfo(
                            stop: next,
                            number: number,
                            total: ordered.count,
                            packages: snapshot.packages(for: next.id),
                            ledger: ledger,
                            visit: visit(for: next.id),
                            timeZone: snapshot.route.timeZone,
                            details: { sheet = .stop(next.id) }
                        )
                        .onAppear { selectedStopID = next.id }
                    } else if snapshot.stops.isEmpty {
                        StateMessageView(symbol: "shippingbox", title: "No stops on this route", message: "Add stops in Plan, then come back to deliver.", actions: [.init(title: "Add stops", symbol: "plus") { sheet = .addStops }])
                    } else {
                        AllDoneCard(summary: summary) { confirmFinish = true }
                    }

                    NeedsDecisionSection(snapshot: snapshot)

                    ViewThatFits(in: .horizontal) {
                      HStack {
                        Button {
                            sheet = .optimize
                        } label: {
                            Label("Re-plan remaining", systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityHint("Optimizes only the stops not yet handled, from your location or a stop you choose")
                        Spacer()
                        if next != nil {
                            Button("Finish early…") { confirmFinish = true }
                                .font(.subheadline)
                                .frame(minHeight: Theme.minTouch)
                        }
                      }
                      VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Button { sheet = .optimize } label: { Label("Re-plan remaining", systemImage: "arrow.triangle.branch") }
                            .buttonStyle(SecondaryButtonStyle())
                        if next != nil {
                            Button("Finish early…") { confirmFinish = true }.frame(minHeight: Theme.minTouch)
                        }
                      }
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)
            }
            if let next {
                DeliveryActionBar(
                    destination: [next.address.streetLine ?? next.address.singleLine, next.address.unitLabel].compactMap { $0 }.joined(separator: " · "),
                    canNavigate: NavigationLauncher.canNavigate(to: next),
                    navigate: { navigate(to: next) },
                    delivered: { act(.delivered, at: next) },
                    failed: { act(.failed, at: next) },
                    skip: { act(.skipped, at: next) }
                )
            }
        }
        .sheet(item: $outcomeSheet) { item in
            switch item {
            case let .packages(stop, kind):
                PackageOutcomeSheet(stop: stop, packages: snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled }, kind: kind) { chosen, reason in
                    record(kind, at: stop, packageIDs: chosen, reason: reason)
                }
            case let .failure(stop, ids):
                FailureReasonSheet { reason, note in record(.failed, at: stop, packageIDs: ids, reason: reason, note: note) }
            }
        }
        .sheet(item: $photoFor) { target in
            PODCaptureView(routeID: snapshot.route.id, stopID: target.stopID, packageIDs: target.packageIDs)
        }
        .confirmationDialog("Navigate with", isPresented: Binding(get: { choosingNavApp != nil }, set: { if !$0 { choosingNavApp = nil } }), titleVisibility: .visible) {
            Button("Apple Maps") { if let s = choosingNavApp { launch(s, .appleMaps) } }
            Button("Google Maps") { if let s = choosingNavApp { launch(s, .googleMaps) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Finish this route?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish route") { services.store.finish(snapshot); toasts.show("Route finished. Find it in History.", symbol: "flag.checkered", tone: .success) }
            Button("Keep delivering", role: .cancel) {}
        } message: {
            let s = snapshot.summary()
            Text(s.pending + s.skipped > 0 ? "\(s.pending + s.skipped) package(s) are not delivered. They stay on record as not handled." : "All packages have an outcome.")
        }
        .alert("Couldn't open navigation", isPresented: Binding(get: { navError != nil }, set: { if !$0 { navError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(navError ?? "") }
        .onChange(of: snapshot.nextStop()?.id, initial: true) { _, id in selectedStopID = id }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let handoff = services.navigation.lastHandoff, handoff.routeID == snapshot.route.id else { return }
            if Date().timeIntervalSince(handoff.at) < 6 * 3600 { returnedFromNavigation = handoff.stopID; selectedStopID = handoff.stopID }
        }
    }

    private func visit(for id: StopID) -> PlannedVisit? {
        if case let .current(p) = planState { return p.visits.first { $0.stopID == id } }
        return nil
    }

    private func navigate(to stop: Stop) {
        switch services.settings.settings.navigationApp {
        case .ask: choosingNavApp = stop
        case let app: launch(stop, app)
        }
    }

    private func launch(_ stop: Stop, _ app: NavigationApp) {
        Task {
            do { try await services.navigation.open(stop: stop, routeID: snapshot.route.id, using: app) } catch { navError = error.localizedDescription }
        }
    }

    private func act(_ kind: OutcomeKind, at stop: Stop) {
        let open = snapshot.packages(for: stop.id).filter { !snapshot.ledger.status(of: $0.id).isHandled }
        guard !open.isEmpty else { return }
        if open.count > 1 && kind != .skipped {
            outcomeSheet = .packages(stop, kind)
        } else if kind == .failed {
            outcomeSheet = .failure(stop, open.map(\.id))
        } else {
            record(kind, at: stop, packageIDs: open.map(\.id))
        }
    }

    private func record(_ kind: OutcomeKind, at stop: Stop, packageIDs: [PackageID], reason: FailureReason? = nil, note: String? = nil) {
        guard !packageIDs.isEmpty else { return }
        let label = "\(kind == .delivered ? "Delivered" : kind == .failed ? "Failed" : "Skipped") \(stop.address.streetLine ?? "stop")"
        let ids = services.store.record(kind, packageIDs: packageIDs, stopID: stop.id, reason: reason, note: note, in: snapshot, label: label)
        if returnedFromNavigation == stop.id { returnedFromNavigation = nil; services.navigation.clearHandoff() }
        switch kind {
        case .delivered: Haptics.success()
        case .failed: Haptics.warning()
        default: Haptics.tap()
        }
        let message = packageIDs.count > 1 ? "\(label) · \(packageIDs.count) packages" : label
        toasts.show(message, symbol: kind == .delivered ? "checkmark.circle.fill" : kind == .failed ? "xmark.octagon.fill" : "arrow.uturn.forward.circle.fill", tone: kind == .delivered ? .success : kind == .failed ? .danger : .warning, undo: {
            services.store.undo(outcomeIDs: ids, in: snapshot)
            Haptics.tap()
        }, extraTitle: kind == .delivered ? "Photo" : nil, extra: kind == .delivered ? { photoFor = PhotoTarget(stopID: stop.id, packageIDs: packageIDs) } : nil)
    }
}

struct ProgressHeader: View {
    var summary: RouteSummary

    var body: some View {
        let handled = summary.delivered + summary.failed + summary.excluded
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ProgressView(value: Double(handled), total: Double(max(summary.packageCount, 1)))
                .tint(Theme.success)
            HStack {
                Text("\(handled) of \(summary.packageCount) packages handled").font(.subheadline.weight(.semibold))
                Spacer()
                if summary.failed > 0 { Label("\(summary.failed)", systemImage: "xmark.octagon").foregroundStyle(Theme.danger).font(.subheadline).accessibilityLabel("\(summary.failed) failed") }
                if summary.skipped > 0 { Label("\(summary.skipped)", systemImage: "arrow.uturn.forward").foregroundStyle(Theme.warning).font(.subheadline).accessibilityLabel("\(summary.skipped) skipped") }
            }
        }
        .padding(.top, Theme.Space.s)
        // Secondary to the stop itself: capped so the address keeps the space at large text sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
    }
}

/// The next stop: everything the driver needs, large and legible.
struct NextStopInfo: View {
    var stop: Stop
    var number: Int
    var total: Int
    var packages: [Package]
    var ledger: DeliveryLedger
    var visit: PlannedVisit?
    var timeZone: TimeZone
    var details: () -> Void

    var body: some View {
        let open = packages.filter { !ledger.status(of: $0.id).isHandled }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Stop \(number) of \(total)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let visit { Text("ETA \(DisplayFormat.time(visit.arrival, timeZone: timeZone))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Button(action: details) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let unit = stop.address.unitLabel { UnitBadge(label: unit) }
                    Text(stop.address.streetLine ?? stop.address.singleLine)
                        .font(.address)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nextStopAddress")
                    Text([stop.address.municipality, stop.address.province?.rawValue, stop.address.postalCode].compactMap { $0 }.joined(separator: " "))
                        .font(.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.row)
            .accessibilityHint("Shows stop details")

            if let w = stop.timeWindow {
                Label(w.explanation, systemImage: w.kind == .hard ? "clock.badge.exclamationmark" : "clock").font(.subheadline).foregroundStyle(Theme.brand)
            }
            if stop.addressStatus != .verified {
                StatusBadge(text: stop.addressStatus.label, symbol: stop.addressStatus.symbol, tone: stop.addressStatus.tone)
            }
            if !stop.notes.isEmpty {
                Label { Text(stop.notes).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "note.text") }
                    .font(.body)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("\(open.count) package\(open.count == 1 ? "" : "s") to deliver").font(.headline)
                ForEach(packages) { p in
                    let status = ledger.status(of: p.id)
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: status.symbolName).foregroundStyle(status.tone.color).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.storageLocation.map { "In: \($0)" } ?? "Location in vehicle not set")
                                .font(.body.weight(p.storageLocation == nil ? .regular : .semibold))
                                .foregroundStyle(p.storageLocation == nil ? .secondary : .primary)
                            Text([p.trackingID.map { "…" + String($0.suffix(6)) }, p.size?.label, p.recipientName, status == .pending ? nil : status.label].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !p.notes.isEmpty {
                                Label(p.notes, systemImage: "note.text")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card()
    }
}

/// Delivery actions, pinned at the bottom of the panel so they are always within thumb reach.
/// Delivered is the largest and lowest control.
struct DeliveryActionBar: View {
    var destination: String
    var canNavigate: Bool
    var navigate: () -> Void
    var delivered: () -> Void
    var failed: () -> Void
    var skip: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Text(destination)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityIdentifier("actionDestination")
            HStack(spacing: Theme.Space.s) {
                Button(action: navigate) { Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                    .buttonStyle(CompactActionStyle(tint: Theme.brand))
                    .disabled(!canNavigate)
                    .accessibilityIdentifier("navigate")
                Button(action: failed) { Label("Failed", systemImage: "xmark.octagon") }
                    .buttonStyle(CompactActionStyle(tint: Theme.danger))
                    .accessibilityIdentifier("failed")
                Button(action: skip) { Label("Skip", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(CompactActionStyle(tint: Theme.neutral))
                    .accessibilityIdentifier("skip")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
            Button(action: delivered) {
                Label("Delivered", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(PrimaryActionButtonStyle(tint: Theme.success))
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .accessibilityIdentifier("delivered")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .background(Theme.elevated.shadow(.drop(color: .black.opacity(0.08), radius: 6, y: -2)))
    }
}

struct CompactActionStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.verticalCompact)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .background(tint.opacity(isEnabled ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct AllDoneCard: View {
    var summary: RouteSummary
    var finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(summary.skipped > 0 ? "Only skipped stops remain" : "All stops handled", systemImage: summary.skipped > 0 ? "arrow.uturn.forward.circle" : "flag.checkered")
                .font(.title3.weight(.semibold))
            Text("Delivered \(summary.delivered) · Failed \(summary.failed) · Skipped \(summary.skipped) · Excluded \(summary.excluded)")
                .font(.subheadline).foregroundStyle(.secondary)
            if summary.skipped > 0 {
                Text("Retry or exclude skipped packages below, or finish the route.").font(.subheadline)
            }
            Button(action: finish) { Label("Finish route", systemImage: "flag.checkered") }
                .buttonStyle(PrimaryActionButtonStyle())
                .accessibilityIdentifier("finishRoute")
        }
        .card()
    }
}

/// Skipped and failed packages stay visible until the driver deliberately retries or excludes them.
struct NeedsDecisionSection: View {
    let snapshot: RouteSnapshot
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let ledger = snapshot.ledger
        let items = snapshot.packages.compactMap { p -> (Package, PackageStatus, Stop)? in
            let s = ledger.status(of: p.id)
            guard let stop = snapshot.stops.first(where: { $0.id == p.stopID }) else { return nil }
            switch s {
            case .skipped, .failed: return (p, s, stop)
            default: return nil
            }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Needs a decision").font(.headline)
                ForEach(items, id: \.0.id) { package, status, stop in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            StatusBadge(text: status.label, symbol: status.symbolName, tone: status.tone, compact: true)
                            Text(stop.address.streetLine ?? "Stop").font(.subheadline.weight(.semibold))
                            if let u = stop.address.unitLabel { Text(u).font(.subheadline).foregroundStyle(Theme.teal) }
                        }
                        HStack {
                            Button("Retry later") { decide(.requeued, package, stop, "Back on the route") }.buttonStyle(SecondaryButtonStyle())
                            Button("Exclude") { decide(.excluded, package, stop, "Excluded from this route") }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
            .card()
        }
    }

    private func decide(_ kind: OutcomeKind, _ package: Package, _ stop: Stop, _ message: String) {
        let ids = services.store.record(kind, packageIDs: [package.id], stopID: stop.id, in: snapshot, label: message)
        toasts.show(message, symbol: kind == .requeued ? "arrow.counterclockwise" : "minus.circle", tone: .neutral) {
            services.store.undo(outcomeIDs: ids, in: snapshot)
        }
    }
}

/// Choose which packages at a multi-package stop get the outcome.
struct PackageOutcomeSheet: View {
    var stop: Stop
    var packages: [Package]
    var kind: OutcomeKind
    var onDone: ([PackageID], FailureReason?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<PackageID> = []
    @State private var reason: FailureReason?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(kind == .delivered ? "Deliver all \(packages.count)" : "All \(packages.count) failed") {
                        chosen = Set(packages.map(\.id))
                    }
                    .font(.headline)
                }
                Section("Packages") {
                    ForEach(Array(packages.enumerated()), id: \.element.id) { index, p in
                        Button {
                            if chosen.contains(p.id) { chosen.remove(p.id) } else { chosen.insert(p.id) }
                        } label: {
                            HStack {
                                Image(systemName: chosen.contains(p.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.brand)
                                VStack(alignment: .leading) {
                                    Text(p.storageLocation ?? "Package").font(.body.weight(.semibold))
                                    Text([p.trackingID, p.size?.label, p.recipientName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: Theme.minTouch)
                        }
                        .accessibilityIdentifier("outcomePackage.\(index)")
                        .accessibilityAddTraits(chosen.contains(p.id) ? .isSelected : [])
                    }
                }
                if kind == .failed {
                    Section("Reason") {
                        ReasonGrid(selection: $reason)
                    }
                }
            }
            .navigationTitle(kind == .delivered ? "Mark delivered" : "Mark failed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onDone(Array(chosen), reason); dismiss() }
                        .disabled(chosen.isEmpty || (kind == .failed && reason == nil))
                        .accessibilityIdentifier("savePackageOutcome")
                }
            }
            .onAppear { chosen = Set(packages.map(\.id)) }
        }
        .presentationDetents(kind == .failed ? [.large] : [.medium, .large])
    }
}

struct FailureReasonSheet: View {
    var onDone: (FailureReason, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: FailureReason?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Why couldn't it be delivered?") { ReasonGrid(selection: $reason) }
                Section("Note (optional)") { TextField("e.g. Gate code not working", text: $note, axis: .vertical) }
            }
            .navigationTitle("Delivery failed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let reason { onDone(reason, note); dismiss() } }
                        .disabled(reason == nil)
                        .accessibilityIdentifier("saveFailure")
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct ReasonGrid: View {
    @Binding var selection: FailureReason?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
            ForEach(FailureReason.allCases, id: \.self) { r in
                Button {
                    selection = r
                    Haptics.selection()
                } label: {
                    Label(r.label, systemImage: r.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 8, alignment: .leading)
                        .padding(.horizontal, Theme.Space.s)
                        .foregroundStyle(selection == r ? .white : Theme.danger)
                        .background(selection == r ? Theme.danger : Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == r ? .isSelected : [])
                .accessibilityIdentifier("reason.\(r.rawValue)")
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}
