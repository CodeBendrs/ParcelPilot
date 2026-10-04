import ParcelPilotKit
import SwiftUI

/// Editable confirmation card. Nothing is added until the driver taps Add (except batch mode, which
/// only auto-adds scans that pass the review policy).
struct AddressConfirmationView: View {
    @State var candidate: IntakeCandidate
    /// Called after the add/save/discard so the presenter can continue (e.g. resume scanning).
    var onFinish: (Outcome) -> Void

    enum Outcome { case added(String), savedForReview, discarded, cancelled }

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var verifying = false
    @State private var pinning = false
    @State private var duplicateWarning: String?

    var body: some View {
        NavigationStack {
            Form {
                if !candidate.alternatives.isEmpty { choiceSection }
                signalsSection
                if let label = candidate.fromLabel, !candidate.driverEdited || candidate.verification != nil { comparisonSection(label) }
                fieldsSection
                reasonsSection
                placementSection
                packageSection
                actionsSection
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                addAction
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.elevated)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(candidate.source == .scan ? "Confirm label" : "Confirm address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(.cancelled); dismiss() } }
            }
            .task { if candidate.verification == nil { await verify() } }
            .sheet(isPresented: $pinning) {
                PinPlacementView(initial: candidate.driverPin ?? candidate.verification?.assessment?.candidate?.location) { point in
                    candidate.driverPin = point
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Sections

    private var choiceSection: some View {
        Section {
            ForEach(Array(candidate.alternatives.enumerated()), id: \.offset) { index, alt in
                Button {
                    candidate.fromLabel = alt
                    candidate.address = alt.address
                    candidate.verification = nil
                    candidate.alternatives = []
                    candidate.roleCertain = true
                    Task { await verify() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusBadge(text: alt.role.label + (alt.roleEvidence.map { " · \($0)" } ?? ""), symbol: alt.role == .sender ? "arrow.up.forward.square" : "person.crop.square", tone: alt.role == .sender ? .warning : .info, compact: true)
                        Text(alt.rawLines.joined(separator: "\n")).font(.body).foregroundStyle(.primary)
                    }
                    .frame(minHeight: Theme.minTouch)
                }
                .accessibilityIdentifier("choice.\(index)")
            }
        } header: {
            Text("Choose the delivery address")
        } footer: {
            Text("This label has more than one address. Pick the recipient — never the sender or return address.")
        }
    }

    private var signalsSection: some View {
        Section {
            let completeness = AddressCompleteness(issues: candidate.parsed.issues)
            if let r = candidate.recognition, !candidate.driverEdited {
                SignalRow(title: "Text recognition", value: r.label, detail: candidate.uncertainFields.isEmpty ? "Recognizer's own reading quality, not a probability that the address is right." : "Uncertain: \(candidate.uncertainFields.map(\.label).joined(separator: ", ")). Check against the label.", symbol: r.symbol, tone: r.tone)
            } else if candidate.driverEdited {
                SignalRow(title: "Text", value: "Typed by you", detail: nil, symbol: "keyboard", tone: .info)
            }
            SignalRow(title: "Address completeness", value: completeness.label, detail: completeness.isComplete ? nil : "Nothing is filled in automatically — add what's missing from the label.", symbol: completeness.isComplete ? "checkmark.circle" : "exclamationmark.circle", tone: completeness.isComplete ? .success : .warning)
            matchSignal
        } header: {
            Text("Checks")
        }
    }

    @ViewBuilder private var matchSignal: some View {
        if let pin = candidate.driverPin {
            SignalRow(title: "Location", value: "Pin placed by you", detail: String(format: "%.5f, %.5f", pin.latitude, pin.longitude), symbol: "mappin", tone: .success)
        } else if verifying {
            HStack { ProgressView(); Text("Checking the address…").foregroundStyle(.secondary) }.frame(minHeight: Theme.minTouch)
        } else if let v = candidate.verification {
            if let a = v.assessment {
                SignalRow(title: "Map match", value: a.quality.label + (a.ambiguous ? " (several buildings)" : ""), detail: matchDetail(a), symbol: a.quality.symbol, tone: a.quality.tone)
            } else {
                SignalRow(title: "Map match", value: v.error?.isOffline == true ? "Needs address verification" : "Not checked", detail: v.error?.localizedDescription, symbol: v.error?.isOffline == true ? "icloud.slash" : "exclamationmark.triangle", tone: .warning)
                Button("Check again") { Task { await verify() } }.frame(minHeight: Theme.minTouch)
            }
        }
    }

    private func matchDetail(_ a: MatchAssessment) -> String {
        switch a.quality {
        case .building: return "The street number, street, province and postal code agree."
        case .synthetic: return "Demo/test data: this location is synthetic and has not been checked against real addresses."
        case .postalArea: return "Only the postal code area was found. That isn't precise enough to deliver to — add the street number or place a pin."
        case .street: return "The street was found but not the building."
        case .municipality: return "Only the city was found."
        case .notFound: return "No match. Check the spelling, or place a pin."
        case .conflict: return "The result is in a different province or country."
        case .buildingWithDifferences: return "A building was found, but some details differ (see below)."
        case .driverPin: return "Location placed by you."
        }
    }

    private func comparisonSection(_ label: DraftCandidate) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("On the label").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(label.rawLines.joined(separator: "\n")).font(.body.monospaced()).textSelection(.enabled)
                if let evidence = label.roleEvidence { Text(evidence).font(.caption).foregroundStyle(.secondary) }
            }
            if let a = candidate.verification?.assessment, let c = a.candidate, a.quality != .notFound {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(c.provider == .google ? "Map result (Google)" : "Map result (\(c.provider.displayName))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(c.formattedAddress).font(.body)
                }
                ForEach(a.differences, id: \.self) { d in
                    Label(d.explanation, systemImage: d.isBlocking ? "exclamationmark.triangle.fill" : "info.circle").font(.subheadline).foregroundStyle(d.isBlocking ? Theme.warning : .secondary)
                }
            }
        } header: {
            Text("Label and map result")
        }
    }

    private var fieldsSection: some View {
        Section {
            field("Recipient", \.recipientName)
            HStack {
                field("Unit / apt", \.unit).accessibilityIdentifier("field.unit")
                field("Type (Apt, App., Suite)", \.unitDesignator)
            }
            HStack {
                field("Number", \.civicNumber).keyboardType(.numbersAndPunctuation).frame(maxWidth: 110).accessibilityIdentifier("field.civic")
                field("Street", \.streetName).accessibilityIdentifier("field.street")
            }
            field("PO box / RR / GD", \.deliveryInstallation)
            field("City", \.municipality)
            Picker("Province", selection: Binding(get: { candidate.address.province }, set: { candidate.address.province = $0; edited() })) {
                Text("Not set").tag(Province?.none)
                ForEach(Province.allCases, id: \.self) { Text("\($0.rawValue) — \($0.englishName)").tag(Province?.some($0)) }
            }
            field("Postal code", \.postalCode).textInputAutocapitalization(.characters).accessibilityIdentifier("field.postal")
            if case let .some(.uncertain(raw, suggestion)) = PostalCodeScanner.read(in: candidate.address.postalCode ?? "") {
                Button("Use \(suggestion.value) instead of \(raw)?") { candidate.address.postalCode = suggestion.value; edited() }
                    .font(.subheadline)
            }
            Button {
                Task { await verify() }
            } label: {
                Label("Check this address", systemImage: "checkmark.magnifyingglass")
            }
            .disabled(verifying)
            .frame(minHeight: Theme.minTouch)
        } header: {
            Text("Delivery address")
        } footer: {
            Text("Accents and unit numbers are kept exactly as entered. The unit stays on the stop card even when navigation goes to the building.")
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<PostalAddress, String?>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(get: { candidate.address[keyPath: keyPath] ?? "" }, set: { candidate.address[keyPath: keyPath] = $0.isEmpty ? nil : $0; edited() }))
                .autocorrectionDisabled()
                .frame(minHeight: Theme.minTouch)
        }
    }

    private func edited() {
        candidate.driverEdited = true
        candidate.verification = nil
        candidate.driverPin = nil
    }

    @ViewBuilder private var reasonsSection: some View {
        let decision = candidate.decision(allowSynthetic: services.verifier.allowsSynthetic)
        if !decision.reasons.isEmpty {
            Section("Needs your review") {
                ForEach(decision.reasons, id: \.self) { r in
                    Label(r.explanation, systemImage: "exclamationmark.triangle").font(.subheadline)
                }
                if let a = candidate.verification?.assessment, !ConfirmationPolicy.mayUseResolvedLocation(a.quality) || a.quality == .street {
                    Button { pinning = true } label: { Label("Place a pin on the map", systemImage: "mappin.and.ellipse") }
                        .frame(minHeight: Theme.minTouch)
                }
            }
        }
    }

    @ViewBuilder private var placementSection: some View {
        if let snapshot = services.store.current, snapshot.route.id == candidate.routeID {
            let index = RouteIntakeIndex(stops: snapshot.stops, packages: snapshot.packages)
            let placement = index.placement(for: candidate.address, trackingID: candidate.package.trackingID)
            let others = index.otherUnitsInBuilding(for: candidate.address)
            Section {
                switch placement {
                case let .duplicateTracking(_, stopID):
                    Banner(symbol: "exclamationmark.2", text: "This tracking number is already on the route (stop \(position(of: stopID, in: snapshot))). It won't be added twice.", tone: .warning)
                case let .existingStop(stopID):
                    let count = snapshot.packages(for: stopID).count
                    Banner(symbol: "shippingbox.and.arrow.backward", text: "Same destination as stop \(position(of: stopID, in: snapshot)). This package will be added to it (\(count + 1) packages).", tone: .info)
                case .newStop:
                    Label("Adds a new stop.", systemImage: "plus.circle").font(.subheadline)
                }
                if !others.isEmpty, placement == .newStop {
                    Label("Another unit in this building is already on the route — this stays a separate stop.", systemImage: "building.2").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func position(of stopID: StopID, in snapshot: RouteSnapshot) -> Int {
        (snapshot.orderedStops.firstIndex { $0.id == stopID } ?? 0) + 1
    }

    private var packageSection: some View {
        Section("Package") {
            TextField("Tracking number", text: Binding(get: { candidate.package.trackingID ?? "" }, set: { candidate.package.trackingID = $0.isEmpty ? nil : $0 }))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            StorageLocationPicker(location: Binding(get: { candidate.package.storageLocation }, set: { candidate.package.storageLocation = $0 }))
            Picker("Size", selection: Binding(get: { candidate.package.size }, set: { candidate.package.size = $0 })) {
                Text("Not set").tag(PackageSize?.none)
                ForEach(PackageSize.allCases, id: \.self) { Text($0.label).tag(PackageSize?.some($0)) }
            }
            TextField("Notes (gate code, leave at side door…)", text: Binding(get: { candidate.package.notes }, set: { candidate.package.notes = $0 }), axis: .vertical)
        }
    }

    private var actionsSection: some View {
        Section {
            let decision = candidate.decision(allowSynthetic: services.verifier.allowsSynthetic)
            let (status, _, _) = candidate.confirmedStop(verifier: services.verifier)
            if !decision.autoAcceptable {
                Text("Will be added as “\(status.label)”." + (status == .verified || status == .driverConfirmed || status == .demoSynthetic ? "" : " It stays on the route but isn't optimized until the address is fixed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if candidate.source == .scan {
                Button("Save for review later") {
                    services.drafts.upsert(candidate.asDraft(allowSynthetic: services.verifier.allowsSynthetic))
                    onFinish(.savedForReview)
                    dismiss()
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
                Button("Discard", role: .destructive) {
                    if let id = candidate.draftID { services.drafts.remove(id) }
                    onFinish(.discarded)
                    dismiss()
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            }
        }
        .listRowBackground(Color.clear)
    }

    private var addAction: some View {
        let (status, _, _) = candidate.confirmedStop(verifier: services.verifier)
        let title = status == .needsReview || status == .unresolvable ? "Add with address warning" : "Add to route"
        return Button(action: add) { Label(title, systemImage: "plus.circle.fill") }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(verifying || (candidate.address.streetName == nil && candidate.address.deliveryInstallation == nil))
            .accessibilityIdentifier("addToRoute")
    }

    // MARK: Actions

    private func verify() async {
        verifying = true
        defer { verifying = false }
        let address = candidate.address
        let result = await services.verifier.verify(address)
        guard candidate.address == address else { return }
        candidate.verification = result
    }

    private func add() {
        guard let snapshot = services.store.current, snapshot.route.id == candidate.routeID else {
            duplicateWarning = "Open the route first."
            return
        }
        let (status, resolution, reasons) = candidate.confirmedStop(verifier: services.verifier)
        let result = services.store.addDelivery(to: snapshot, address: candidate.address, status: status, resolution: resolution, reviewReasons: reasons, packages: [candidate.package], source: candidate.source)
        if let id = candidate.draftID { services.drafts.remove(id) }
        switch result.placement {
        case .duplicateTracking:
            Haptics.warning()
            onFinish(.added("Already on the route — not added again"))
        case .existingStop:
            Haptics.success()
            onFinish(.added("Added to an existing stop"))
        case .newStop:
            Haptics.success()
            onFinish(.added("Added \(candidate.address.streetLine ?? "stop")"))
        }
        dismiss()
    }
}

struct SignalRow: View {
    var title: String
    var value: String
    var detail: String?
    var symbol: String
    var tone: StatusTone

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(tone.color).font(.title3).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold)).foregroundStyle(tone.color)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Quick picks for where a package is in the vehicle, plus free text.
struct StorageLocationPicker: View {
    @Binding var location: String?
    static let quick = ["Front", "Middle", "Back", "Left shelf", "Right shelf", "Floor", "Passenger seat"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Location in vehicle (e.g. Shelf B3, Tote 4)", text: Binding(get: { location ?? "" }, set: { location = $0.isEmpty ? nil : String($0.prefix(60)) }))
                .frame(minHeight: Theme.minTouch)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.quick, id: \.self) { q in
                        Button(q) { location = q; Haptics.selection() }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .frame(minHeight: Theme.minTouch)
                            .background(location == q ? Theme.teal.opacity(0.25) : Theme.brandSoft, in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(location == q ? .isSelected : [])
                    }
                }
            }
        }
    }
}
