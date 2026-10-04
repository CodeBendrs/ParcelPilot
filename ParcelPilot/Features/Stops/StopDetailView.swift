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
    @State private var confirmDelete = false
    @State private var navError: String?

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
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        StopNumberView(number: number, status: ledger.stopStatus(stop, packages: snapshot.packages))
                        StatusBadge(text: stop.addressStatus.label, symbol: stop.addressStatus.symbol, tone: stop.addressStatus.tone, compact: true)
                    }
                    if let unit = stop.address.unitLabel { UnitBadge(label: unit) }
                    Text(stop.address.streetLine ?? stop.address.singleLine).font(.address)
                    Text([stop.address.municipality, stop.address.province?.rawValue, stop.address.postalCode].compactMap { $0 }.joined(separator: " ")).foregroundStyle(.secondary)
                    if let name = stop.address.recipientName { Label(name, systemImage: "person").font(.subheadline) }
                }
                .padding(.vertical, Theme.Space.xs)
                if !stop.reviewReasons.isEmpty {
                    ForEach(stop.reviewReasons, id: \.self) { Label($0.explanation, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Theme.warning) }
                }
                if let r = stop.resolution {
                    LabeledContent("Location", value: locationText(r, now: Date()))
                }
                Button { editingAddress = CandidateBox(candidate: IntakeCandidate(routeID: route.id, source: .manual, address: stop.address, driverEdited: true)) } label: { Label("Edit or re-check address", systemImage: "pencil") }
                Button { pinning = true } label: { Label(stop.resolution?.match == .driverPin ? "Move pin" : "Place pin on map", systemImage: "mappin.and.ellipse") }
                Button { navigate(stop, route) } label: { Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    .disabled(stop.address.civicNumber == nil)
                Button { services.store.setNextStop(stop.id, in: route); toasts.show("Set as next stop", symbol: "arrow.right.circle", tone: .info) } label: { Label("Deliver this stop next", systemImage: "arrow.right.circle") }
            }

            Section("Packages (\(packages.count))") {
                ForEach(packages) { p in
                    let status = ledger.status(of: p.id)
                    Button { editingPackage = p } label: {
                        HStack {
                            Image(systemName: status.symbolName).foregroundStyle(status.tone.color)
                            VStack(alignment: .leading) {
                                Text(p.storageLocation ?? "No vehicle location").font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text([p.trackingID, p.size?.label, status.label].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: Theme.minTouch)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { services.store.delete(package: p, in: snapshot) } }
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
                Text("Planning")
            } footer: {
                Text("Changing a window, pin or stop time makes the current optimized times outdated.")
            }

            Section("Notes") {
                NotesEditor(text: stop.notes) { text in var s = stop; s.notes = String(text.prefix(2000)); services.store.update(stop: s, in: route, invalidatesPlan: false) }
            }

            let outcomes = snapshot.outcomes.filter { $0.stopID == stop.id }.sorted { $0.recordedAt > $1.recordedAt }
            if !outcomes.isEmpty {
                Section("History") {
                    ForEach(outcomes) { o in
                        HStack {
                            Text(o.kind.rawValue.capitalized + (o.reason.map { " · \($0.label)" } ?? "")).strikethrough(o.voidedAt != nil)
                            Spacer()
                            Text(DisplayFormat.time(o.recordedAt, timeZone: route.timeZone)).foregroundStyle(.secondary).font(.subheadline.monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(o.voidedAt != nil ? "undone" : "")
                    }
                }
            }

            PhotosSection(snapshot: snapshot, stop: stop) { photoTarget = true }

            Section {
                Button("Remove stop and its packages", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("Stop \(number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: $editingAddress) { box in
            AddressEditSheet(candidate: box.candidate, stop: stop, route: route)
        }
        .sheet(item: $editingPackage) { p in PackageEditor(package: p, route: route, isNew: !packages.contains { $0.id == p.id }) }
        .sheet(isPresented: $pinning) {
            PinPlacementView(initial: stop.resolution?.located?.point) { point in
                var s = stop
                s.resolution = StopResolution(provider: nil, placeID: stop.resolution?.placeID, located: LocatedPoint(point: point, source: .driverPin), match: .driverPin, resolvedAt: Date())
                s.addressStatus = .driverConfirmed
                services.store.update(stop: s, in: route, invalidatesPlan: true)
            }
        }
        .sheet(isPresented: $photoTarget) {
            PODCaptureView(routeID: route.id, stopID: stop.id, packageIDs: packages.map(\.id))
        }
        .confirmationDialog("Remove this stop?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove stop", role: .destructive) {
                services.store.delete(stop: stop, from: snapshot)
                toasts.show("Stop removed", symbol: "trash", tone: .neutral, undo: {
                    services.store.restore(stop: stop, packages: packages, in: route.id)
                })
                dismiss()
            }
        } message: { Text("Its \(packages.count) package(s) are removed from the route. Recorded outcomes stay in history.") }
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

    private func navigate(_ stop: Stop, _ route: Route) {
        Task {
            let app = services.settings.settings.navigationApp == .ask ? NavigationApp.appleMaps : services.settings.settings.navigationApp
            do { try await services.navigation.open(stop: stop, routeID: route.id, using: app) } catch { navError = error.localizedDescription }
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
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
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
        candidate.verification = await services.verifier.verify(candidate.address)
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
        services.store.update(stop: s, in: route, invalidatesPlan: true)
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
                        services.store.commitPrepared([.putPackage(route.id, package), .updateRoute(currentRoute, bumpRevision: true)], label: "Add package")
                    } else {
                        services.store.update(package: package, in: route)
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
            if kind == 1 {
                MinutePicker(title: "From", minute: $start, timeZone: route.timeZone, allowNextDay: true)
                MinutePicker(title: "Until", minute: $end, timeZone: route.timeZone, allowNextDay: true)
                Text("Hard window: the plan may wait if early and reports a conflict rather than arriving late.").font(.caption).foregroundStyle(.secondary)
                if end <= start { Text("“Until” must be after “From”. For a window past midnight, turn on Next day.").font(.caption).foregroundStyle(Theme.danger) }
            } else if kind == 2 {
                MinutePicker(title: "Arrive by", minute: $end, timeZone: route.timeZone, allowNextDay: true)
                Text("Soft deadline: the optimizer tries to arrive by this time but may arrive later if needed.").font(.caption).foregroundStyle(.secondary)
            }
            if kind != currentKind || (kind != 0 && (start != stop.timeWindow?.startMinute ?? start || end != stop.timeWindow?.endMinute)) {
                Button("Save delivery time") { save() }
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
        services.store.update(stop: s, in: route, invalidatesPlan: true)
        Haptics.success()
    }
}
