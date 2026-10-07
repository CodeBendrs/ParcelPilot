import ParcelPilotKit
import SwiftUI

struct StopDetailView: View {
    let stopID: StopID
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var editingAddress: CandidateBox?
    @State private var editingPackage: Package?
    @State private var pinning = false
    @State private var photoTarget = false
    @State private var viewingPhoto: DeliveryPhoto?
    @State private var confirmDelete = false
    @State private var navError: String?
    @State private var choosingNavApp = false
    @State private var removedPackage: Package?
    @State private var continuingFrom: Stop?

    var body: some View {
        NavigationStack {
            if let snapshot = services.store.current, let stop = snapshot.stops.first(where: { $0.id == stopID }) {
                content(snapshot, stop)
            } else {
                StateMessageView(symbol: "questionmark.square.dashed", title: "Stop not found", message: "It may have been removed on another device.", actions: [.init(title: "Close", symbol: nil) { dismiss() }])
            }
        }
    }

    private func content(_ snapshot: RouteSnapshot, _ stop: Stop) -> some View {
        let ledger = snapshot.ledger
        let packages = snapshot.packages(for: stop.id)
        let number = (snapshot.orderedStops.firstIndex { $0.id == stop.id } ?? 0) + 1
        let route = snapshot.route
        return List {
            if let issue = services.store.persistenceIssue {
                Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
            }
            Section {
                DeliveryDestination(stop: stop, timeZone: route.timeZone)
                StatusBadge(text: stop.addressStatus.label, symbol: stop.addressStatus.symbol, tone: stop.addressStatus.tone, compact: true)
                if !stop.reviewReasons.isEmpty {
                    ForEach(stop.reviewReasons, id: \.self) { Label($0.explanation, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Theme.warning) }
                }
                if let r = stop.resolution {
                    LabeledContent("Location", value: locationText(r, now: Date()))
                }

            }

            Section("Stop work") {
                StopWorkContent(snapshot: snapshot, stop: stop, allowsEditing: true)
            }

            Section("Packages (\(packages.count))") {
                ForEach(packages) { p in
                    let status = ledger.status(of: p.id)
                    Button { editingPackage = p } label: {
                        HStack {
                            Image(systemName: status.symbolName).foregroundStyle(status.tone.color)
                            VStack(alignment: .leading) {
                                Text(p.storageLocation ?? "No vehicle location").font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text([p.trackingID, p.size?.label, status.label].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.neutral)
                            }
                        }
                        .frame(minHeight: Theme.minTouch)
                    }
                    .buttonStyle(.row)
                    .accessibilityIdentifier("packageRow.\(p.id)")
                    .swipeActions { Button("Remove", role: .destructive) {
                        guard services.store.delete(package: p, in: snapshot).isCommitted else { return }
                        removedPackage = p
                    } }
                    Button("Remove package", role: .destructive) {
                        guard services.store.delete(package: p, in: snapshot).isCommitted else { return }
                        removedPackage = p
                    }.frame(minHeight: 44).accessibilityIdentifier("removePackage.\(p.id)")
                }
                if let removedPackage {
                    Button("Undo remove package", systemImage: "arrow.uturn.backward") {
                        guard services.store.restore(package: removedPackage, in: route.id).isCommitted else { return }
                        self.removedPackage = nil
                    }
                    .frame(minHeight: Theme.minTouch)
                }
                Button { addPackage(snapshot, stop) } label: { Label("Add another package", systemImage: "plus") }
            }

            Section {
                TimeWindowEditor(stop: stop, route: route)
                Picker("Order", selection: Binding(get: { stop.pin }, set: { var s = stop; s.pin = $0; services.store.update(stop: s, in: route, invalidatesPlan: true) })) {
                    ForEach(StopPin.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Stepper("Time at stop: \(DisplayFormat.serviceDuration(seconds: stop.serviceSeconds ?? route.defaultServiceSeconds))\(stop.serviceSeconds == nil ? " (route default)" : "")", onIncrement: {
                    var s = stop; s.serviceSeconds = min(7200, (stop.serviceSeconds ?? route.defaultServiceSeconds) + 30); services.store.update(stop: s, in: route, invalidatesPlan: true)
                }, onDecrement: {
                    var s = stop; s.serviceSeconds = max(0, (stop.serviceSeconds ?? route.defaultServiceSeconds) - 30); services.store.update(stop: s, in: route, invalidatesPlan: true)
                })
            } header: {
                Text("Delivery window & planning")
            } footer: {
                Text("Changing a window, pin or stop time makes the current optimized times outdated.")
            }

            Section("Notes") {
                NotesEditor(text: stop.notes) { text in
                    let notes = String(text.prefix(2000))
                    guard notes != stop.notes else { return }
                    var s = stop
                    s.notes = notes
                    services.store.update(stop: s, in: route, invalidatesPlan: false)
                }
            }

            let outcomes = snapshot.outcomes.filter { $0.stopID == stop.id }.sorted { $0.recordedAt > $1.recordedAt }
            if !outcomes.isEmpty {
                Section("History") {
                    ForEach(outcomes) { o in
                        HStack {
                            Text(o.kind.rawValue.capitalized + (o.reason.map { " · \($0.label)" } ?? "")).strikethrough(o.voidedAt != nil)
                            Spacer()
                            Text(DisplayFormat.time(o.recordedAt, timeZone: route.timeZone)).foregroundStyle(Theme.neutral).font(.subheadline.monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(o.voidedAt != nil ? "undone" : "")
                    }
                }
            }

            PhotosSection(snapshot: snapshot, stop: stop, add: { photoTarget = true }, view: { viewingPhoto = $0 })

            Section("Address & pin") {
                Button { editingAddress = CandidateBox(candidate: IntakeCandidate(routeID: route.id, source: .manual, address: stop.address, driverEdited: true)) } label: { Label("Edit or re-check address", systemImage: "pencil") }
                    .accessibilityIdentifier("editStopAddress")
                Button { pinning = true } label: { Label(stop.resolution?.match == .driverPin ? "Move pin" : "Place pin on map", systemImage: "mappin.and.ellipse") }
                    .accessibilityIdentifier("placeStopPin")
            }
            Section("Actions") {
                Button {
                    if let current = snapshot.nextStop(), current.id != stop.id,
                       snapshot.workLedger.hasActionableRequiredWork(at: current.id) {
                        continuingFrom = current
                        services.store.recordPendingWorkReminder(in: snapshot, stopID: current.id)
                    } else { chooseNext(stop, route: route) }
                } label: { Label("Deliver next", systemImage: "arrow.right.circle") }
                    .frame(minHeight: 44).accessibilityIdentifier("deliverNext")
                Button { navigate(stop, route) } label: { Label("Navigate", systemImage: "location") }
                    .disabled(!NavigationLauncher.canNavigate(to: stop))
            }

            Section {
                Button("Remove stop and its packages", role: .destructive) { confirmDelete = true }
            }
        }
        .toasts(toasts)
        .navigationTitle("Stop \(number)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { services.store.recordWorkPresentation(in: snapshot, stopID: stop.id) }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeStopDetail") } }
        .sheet(item: $editingAddress) { box in
            AddressEditSheet(candidate: box.candidate, stop: stop, route: route)
        }
        .sheet(item: $editingPackage) { p in PackageEditor(package: p, route: route, isNew: !packages.contains { $0.id == p.id }) }
        .sheet(isPresented: $pinning) {
            PinPlacementView(initial: stop.resolution?.located?.point) { point in
                var s = stop
                s.resolution = StopResolution(provider: nil, placeID: stop.resolution?.placeID, located: LocatedPoint(point: point, source: .driverPin), match: .driverPin, resolvedAt: Date())
                s.addressStatus = .driverConfirmed
                return services.store.update(stop: s, in: route, invalidatesPlan: true).isCommitted
            }
        }
        .sheet(isPresented: $photoTarget) {
            PODCaptureView(routeID: route.id, stopID: stop.id, packageIDs: packages.map(\.id))
        }
        .sheet(item: $viewingPhoto) { photo in PhotoViewer(photo: photo, routeID: route.id) }
        .confirmationDialog("Remove this stop?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove stop", role: .destructive) {
                guard services.store.delete(stop: stop, from: snapshot).isCommitted else { return }
                toasts.show("Stop removed", symbol: "trash", tone: .neutral, undoAcknowledged: {
                    services.store.restore(stop: stop, packages: packages, tasks: snapshot.tasks.filter { $0.stopID == stop.id }, in: route.id).isCommitted
                })
                dismiss()
            }
        } message: { Text("Its \(packages.count) package(s) are removed from the route. Recorded outcomes stay in history.") }
        .confirmationDialog("Navigate with", isPresented: $choosingNavApp, titleVisibility: .visible) {
            Button("Apple Maps") { launch(stop, route, using: .appleMaps) }
            Button("Google Maps") { launch(stop, route, using: .googleMaps) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Required work is still pending", isPresented: Binding(get: { continuingFrom != nil }, set: { if !$0 { continuingFrom = nil } }), titleVisibility: .visible) {
            Button("Continue to this stop") {
                if let prior = continuingFrom { services.store.recordPendingWorkReminder(in: snapshot, stopID: prior.id, bypassed: true) }
                continuingFrom = nil
                chooseNext(stop, route: route)
            }.accessibilityIdentifier("continueWithPendingWork")
            Button("Keep current stop") { continuingFrom = nil }
                .accessibilityIdentifier("keepCurrentStop")
        } message: {
            if let prior = continuingFrom {
                let pending = snapshot.workLedger.actionableTasks(at: prior.id).filter(\.required)
                let pickups = pending.filter { $0.kind == .pickup }.count
                Text(pickups > 0 ? "\(pickups) required pickup(s) still pending at your current stop. Continuing preserves all unfinished work." : "\(pending.count) required item(s) still pending at your current stop. Continuing preserves all unfinished work.")
            }
        }
        .alert("Couldn't open navigation", isPresented: Binding(get: { navError != nil }, set: { if !$0 { navError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(navError ?? "") }
    }

    private func locationText(_ r: StopResolution, now: Date) -> String {
        guard let l = r.located else { return r.placeID != nil ? "Location will be refreshed" : "No location" }
        switch l.source {
        case .driverPin: return "Your pin"
        case .deviceLocation: return "Your location"
        case .providerGeocode: return l.isUsable(at: now) ? "Google (kept until \(DisplayFormat.dateTime(l.expiresAt ?? now, timeZone: .current)))" : "Expired — will refresh"
        case .demoSynthetic: return "Synthetic (demo)"
        case .emulatorFake: return "Synthetic (emulator)"
        }
    }

    private func addPackage(_ snapshot: RouteSnapshot, _ stop: Stop) {
        let p = Package(stopID: stop.id, recipientName: stop.address.recipientName, source: .manual)
        editingPackage = p
    }

    private func chooseNext(_ stop: Stop, route: Route) {
        guard services.store.setNextStop(stop.id, in: route).isCommitted else { return }
        toasts.show("Set as next stop", symbol: "arrow.right.circle", tone: .info)
        dismiss()
    }

    private func navigate(_ stop: Stop, _ route: Route) {
        let app = services.settings.settings.navigationApp
        if app == .ask { choosingNavApp = true }
        else { launch(stop, route, using: app) }
    }

    private func launch(_ stop: Stop, _ route: Route, using app: NavigationApp) {
        Task {
            do { try await services.navigation.open(stop: stop, routeID: route.id, using: app) }
            catch { navError = error.localizedDescription }
        }
    }
}

/// Re-confirm an existing stop's address. Saving re-verifies and invalidates the plan.
struct AddressEditSheet: View {
    @State var candidate: IntakeCandidate
    let stop: Stop
    let route: Route
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                if let issue = services.store.persistenceIssue {
                    Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
                }
                Section("Address") {
                    TextField("Recipient", text: binding(\.recipientName))
                    HStack { TextField("Unit", text: binding(\.unit)); TextField("Type", text: binding(\.unitDesignator)) }
                    HStack { TextField("Number", text: binding(\.civicNumber)).frame(maxWidth: 110); TextField("Street", text: binding(\.streetName)) }
                    TextField("PO box / RR / GD", text: binding(\.deliveryInstallation))
                    TextField("City", text: binding(\.municipality))
                    Picker("Province", selection: Binding(get: { candidate.address.province }, set: { candidate.address.province = $0; candidate.verification = nil })) {
                        Text("Not set").tag(Province?.none)
                        ForEach(Province.allCases, id: \.self) { Text($0.rawValue).tag(Province?.some($0)) }
                    }
                    TextField("Postal code", text: binding(\.postalCode)).textInputAutocapitalization(.characters)
                }
                Section("Check") {
                    if checking { ProgressView() }
                    if let a = candidate.verification?.assessment {
                        SignalRow(title: "Map match", value: a.quality.label, detail: a.differences.map(\.explanation).joined(separator: " "), symbol: a.quality.symbol, tone: a.quality.tone)
                    } else if let e = candidate.verification?.error {
                        Text(e.localizedDescription).font(.subheadline)
                    }
                    Button("Check address") { Task { await check() } }
                }
            }
            .navigationTitle("Edit address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(checking) }
            }
            .task { await check() }
        }
    }

    private func binding(_ kp: WritableKeyPath<PostalAddress, String?>) -> Binding<String> {
        Binding(get: { candidate.address[keyPath: kp] ?? "" }, set: { candidate.address[keyPath: kp] = $0.isEmpty ? nil : $0; candidate.verification = nil })
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let address = candidate.address
        let result = await services.verifier.verify(address)
        guard candidate.address == address else { return }
        candidate.verification = result
    }

    private func save() async {
        // A result checked only now, on Save, hasn't been seen by the driver: it can't count as confirmed.
        let seenResult = candidate.verification != nil
        if !seenResult { await check() }
        let (status, resolution, reasons) = candidate.confirmedStop(verifier: services.verifier, driverReviewed: seenResult)
        var s = stop
        s.address = candidate.address
        s.addressStatus = status
        s.resolution = resolution
        s.reviewReasons = reasons
        guard services.store.update(stop: s, in: route, invalidatesPlan: true).isCommitted else { return }
        dismiss()
    }
}

struct PackageEditor: View {
    @State var package: Package
    let route: Route
    var isNew = false
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let issue = services.store.persistenceIssue {
                    Section { Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger) }
                }
                TextField("Tracking number", text: Binding(get: { package.trackingID ?? "" }, set: { package.trackingID = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Recipient", text: Binding(get: { package.recipientName ?? "" }, set: { package.recipientName = $0.isEmpty ? nil : $0 }))
                StorageLocationPicker(location: $package.storageLocation)
                Picker("Size", selection: $package.size) {
                    Text("Not set").tag(PackageSize?.none)
                    ForEach(PackageSize.allCases, id: \.self) { Text($0.label).tag(PackageSize?.some($0)) }
                }
                TextField("Notes", text: $package.notes, axis: .vertical)
            }
            .navigationTitle("Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if isNew {
                        let currentRoute = services.store.current?.route ?? route
                        guard services.store.commitPrepared([.putPackage(route.id, package), .updateRoute(currentRoute, bumpRevision: true)], label: "Add package").isCommitted else { return }
                    } else {
                        guard services.store.update(package: package, in: route).isCommitted else { return }
                    }
                    dismiss()
                }
                .accessibilityIdentifier("savePackage") }
            }
        }
        .presentationDetents([.large])
    }
}

struct NotesEditor: View {
    @State var text: String
    var save: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Access codes, buzzer, where to leave it…", text: $text, axis: .vertical)
            .lineLimit(2...6)
            .focused($focused)
            .onChange(of: focused) { _, f in if !f { save(text) } }
            .onSubmit { save(text) }
            .onDisappear { save(text) }
    }
}

/// Hard window vs soft deadline, with plain semantics.
struct TimeWindowEditor: View {
    let stop: Stop
    let route: Route
    @Environment(AppServices.self) private var services
    @State private var kind: Int = 0
    @State private var start = 9 * 60
    @State private var end = 11 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Delivery time", selection: $kind) {
                Text("Any time").tag(0)
                Text("Must arrive within").tag(1)
                Text("Prefer to arrive by").tag(2)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("deliveryTimePicker")
            if kind == 1 {
                MinutePicker(title: "From", minute: $start, timeZone: route.timeZone, allowNextDay: true)
                MinutePicker(title: "Until", minute: $end, timeZone: route.timeZone, allowNextDay: true)
                Text("Hard window: the plan may wait if early and reports a conflict rather than arriving late.").font(.footnote).foregroundStyle(Theme.neutral)
                if end <= start { Text("“Until” must be after “From”. For a window past midnight, turn on Next day.").font(.caption).foregroundStyle(Theme.danger) }
            } else if kind == 2 {
                MinutePicker(title: "Arrive by", minute: $end, timeZone: route.timeZone, allowNextDay: true)
                Text("Soft deadline: the optimizer tries to arrive by this time but may arrive later if needed.").font(.footnote).foregroundStyle(Theme.neutral)
            }
            if kind != currentKind || (kind != 0 && (start != stop.timeWindow?.startMinute ?? start || end != stop.timeWindow?.endMinute)) {
                Button("Save delivery time") { save() }
                    .accessibilityIdentifier("saveDeliveryTime")
                    .disabled(kind == 1 && end <= start)
                    .frame(minHeight: Theme.minTouch)
            }
        }
        .onAppear {
            kind = currentKind
            start = stop.timeWindow?.startMinute ?? 9 * 60
            end = stop.timeWindow?.endMinute ?? 11 * 60
        }
    }

    private var currentKind: Int {
        switch stop.timeWindow?.kind {
        case .none: return 0
        case .hard: return 1
        case .softDeadline: return 2
        }
    }

    private func save() {
        var s = stop
        switch kind {
        case 1: s.timeWindow = TimeWindowConstraint(kind: .hard, startMinute: start, endMinute: end)
        case 2: s.timeWindow = TimeWindowConstraint(kind: .softDeadline, startMinute: nil, endMinute: end)
        default: s.timeWindow = nil
        }
        guard services.store.update(stop: s, in: route, invalidatesPlan: true).isCommitted else { return }
        Haptics.success()
    }
}
