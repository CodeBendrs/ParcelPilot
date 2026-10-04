import GoogleMaps
import MapKit
import ParcelPilotKit
import SwiftUI

struct AddStopsMenu: View {
    let snapshot: RouteSnapshot
    @Binding var sheet: WorkspaceSheet?
    var selectTab: (AppTab) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { dismiss(); selectTab(.scan) } label: { menuRow("Scan package labels", "Camera reads the SHIP TO address. Batch mode for many packages.", "barcode.viewfinder") }
                Button { sheet = .manualAdd } label: { menuRow("Search an address", "Type an address and confirm the match.", "magnifyingglass") }
                    .accessibilityIdentifier("addManual")
                Button { sheet = .paste } label: { menuRow("Paste a list", "One address per line, or blank lines between addresses.", "doc.on.clipboard") }
                    .accessibilityIdentifier("addPaste")
                Button { sheet = .csv } label: { menuRow("Import CSV", "Map columns, review errors and duplicates.", "tablecells") }
                    .accessibilityIdentifier("addCSV")
                let drafts = services.drafts.drafts(for: snapshot.route.id).count
                if drafts > 0 {
                    Button { sheet = .reviewQueue } label: { menuRow("Review queue (\(drafts))", "Scanned labels that need a decision.", "tray.full") }
                }
            }
            .navigationTitle("Add stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func menuRow(_ title: String, _ detail: String, _ symbol: String) -> some View {
        menuRowContent(title, detail, symbol).contentShape(Rectangle())
    }

    private func menuRowContent(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.brand).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: Theme.minTouch + 8)
    }
}

/// Type an address (with Google suggestions) → confirmation card. A picked suggestion arrives already
/// checked; typed text is parsed and verified on the card.
struct ManualAddView: View {
    let routeID: RouteID
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @State private var confirmation: CandidateBox?
    @State private var suggestions = AddressSuggestionsModel()
    @State private var pickError: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Unit 204, 123 Example St, Victoria BC V8W 1A1", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("manualAddressField")
                        .onChange(of: text) { _, newValue in
                            pickError = nil
                            suggestions.queryChanged(newValue, resolver: services.resolver, near: AddressSuggestionsModel.bias(for: services.store.current))
                        }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Start typing and pick a suggestion, or type the full address with the unit, street number, city, province and postal code. You can check and edit every field on the next screen.")
                }
                AddressSuggestionsSection(model: suggestions) { pick($0) }
                if let pickError {
                    Section { Banner(symbol: "exclamationmark.triangle", text: pickError, tone: .warning) }
                }
                Section {
                    Button { next() } label: { Label("Continue", systemImage: "arrow.right") }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
                        .accessibilityIdentifier("manualContinue")
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Search an address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = true }
            .sheet(item: $confirmation) { box in
                AddressConfirmationView(candidate: box.candidate) { outcome in
                    if case let .added(message) = outcome {
                        toasts.show(message, symbol: "checkmark.circle.fill", tone: .success)
                        dismiss()
                    }
                }
            }
        }
    }

    /// The suggestion's own result fills the address, so the card opens already checked. A unit the
    /// driver typed is kept when Google's result has none.
    private func pick(_ suggestion: AddressSuggestion) {
        Task {
            do {
                let response = try await suggestions.pick(suggestion, resolver: services.resolver)
                guard let result = response.candidates.first else {
                    pickError = "That suggestion couldn't be found. Type the full address instead."
                    return
                }
                var address = PostalAddress(candidate: result)
                let typed = CanadianAddressParser.parse(singleLine: text).address
                if address.unit == nil, let unit = typed.unit {
                    address.unit = unit
                    address.unitDesignator = typed.unitDesignator
                }
                var c = IntakeCandidate(routeID: routeID, source: .manual, address: address)
                c.driverEdited = true
                let assessment = MatchAssessor.assess(address: address, candidates: response.candidates)
                c.verification = AddressVerifier.Result(response: response, assessment: assessment, resolution: .resolved(assessment), error: nil)
                confirmation = CandidateBox(candidate: c)
            } catch {
                pickError = (error as? ServiceError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    private func next() {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let parsed = CanadianAddressParser.parse(lines: lines)
        var c = IntakeCandidate(routeID: routeID, source: .manual, address: parsed.address)
        c.driverEdited = true
        c.package.recipientName = parsed.address.recipientName
        confirmation = CandidateBox(candidate: c)
    }
}

struct CandidateBox: Identifiable {
    let id = UUID()
    var candidate: IntakeCandidate
}

/// Address search for route start/end places.
struct PlaceSearchView: View {
    var title: String
    var onPick: (RoutePlace) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GeocodeCandidate] = []
    @State private var response: ResolveResponse?
    @State private var searching = false
    @State private var error: String?
    @State private var suggestions = AddressSuggestionsModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Address or postal code", text: $query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                        .onChange(of: query) { _, newValue in
                            suggestions.queryChanged(newValue, resolver: services.resolver, near: AddressSuggestionsModel.bias(for: services.store.current))
                        }
                    Button("Search") { Task { await search() } }.disabled(query.count < 3 || searching)
                }
                AddressSuggestionsSection(model: suggestions) { suggestion in
                    Task { await pick(suggestion) }
                }
                if searching { ProgressView() }
                if let error { Banner(symbol: "exclamationmark.triangle", text: error, tone: .warning) }
                ForEach(results) { c in
                    Button {
                        pick(c)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.formattedAddress).foregroundStyle(.primary)
                            Text(c.provider == .google ? "Google result" : c.provider.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: Theme.minTouch)
                    }
                }
                Section {
                    Button("Use what I typed (verify later)") {
                        let parsed = CanadianAddressParser.parse(singleLine: query)
                        onPick(RoutePlace(label: query, address: parsed.address))
                        dismiss()
                    }
                    .disabled(query.count < 3)
                } footer: {
                    Text("Without a verified location the route can't be optimized from this place — use your current location instead, or search again online.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func search() async {
        searching = true
        error = nil
        defer { searching = false }
        do {
            let r = try await services.resolver.resolve(.query(query))
            response = r
            results = r.candidates.filter { ConfirmationPolicy.mayUseResolvedLocation(MatchAssessor.assess(address: CanadianAddressParser.parse(singleLine: query).address, candidate: $0).quality) || $0.types.contains("street_address") || $0.types.contains("premise") }
            if results.isEmpty { error = "No building-level match. Try a fuller address." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pick(_ suggestion: AddressSuggestion) async {
        error = nil
        do {
            let r = try await suggestions.pick(suggestion, resolver: services.resolver)
            guard let c = r.candidates.first else {
                error = "That suggestion couldn't be found. Try a fuller address."
                return
            }
            response = r
            let source: PointSource = c.provider == .google ? .providerGeocode : c.provider == .demo ? .demoSynthetic : .emulatorFake
            let located = LocatedPoint(point: c.location, source: source, expiresAt: source == .providerGeocode ? r.coordinatesExpireAt : nil)
            onPick(RoutePlace(label: c.formattedAddress, address: PostalAddress(candidate: c), located: located, placeID: c.placeID))
            dismiss()
        } catch {
            self.error = (error as? ServiceError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func pick(_ c: GeocodeCandidate) {
        let source: PointSource = c.provider == .google ? .providerGeocode : c.provider == .demo ? .demoSynthetic : .emulatorFake
        let located = LocatedPoint(point: c.location, source: source, expiresAt: source == .providerGeocode ? response?.coordinatesExpireAt : nil)
        let parsed = CanadianAddressParser.parse(singleLine: query).address
        onPick(RoutePlace(label: c.formattedAddress, address: parsed, located: located, placeID: c.placeID))
        dismiss()
    }
}

/// Driver places the delivery location by hand (rural routes, new buildings, poor geocodes). The pin
/// is driver data, not provider content.
struct PinPlacementView: View {
    var initial: GeoPoint?
    var onPick: (GeoPoint) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var center: GeoPoint?
    @State private var locating = false

    var body: some View {
        NavigationStack {
            ZStack {
                switch services.mapStyle {
                case .google:
                    GooglePinMap(center: $center, initial: initial)
                case .apple:
                    ApplePinMap(center: $center, initial: initial)
                case let .googleUnavailable(reason):
                    Text(reason).padding().multilineTextAlignment(.center)
                }
                Image(systemName: "mappin")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Theme.danger)
                    .offset(y: -18)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Theme.Space.s) {
                    Text("Move the map so the pin is on the delivery door.").font(.subheadline)
                    Button {
                        Task {
                            locating = true
                            defer { locating = false }
                            if let c = try? await services.location.currentLocation() { center = GeoPoint(latitude: c.latitude, longitude: c.longitude) }
                        }
                    } label: { Label(locating ? "Locating…" : "I'm at the delivery spot", systemImage: "location") }
                        .buttonStyle(SecondaryButtonStyle())
                    Button { if let center { onPick(center); dismiss() } } label: { Text("Use this location") }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(center == nil)
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Place a pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct GooglePinMap: UIViewRepresentable {
    @Binding var center: GeoPoint?
    var initial: GeoPoint?

    func makeCoordinator() -> Coordinator { Coordinator(center: $center) }

    func makeUIView(context: Context) -> GMSMapView {
        let start = initial ?? GeoPoint(latitude: 45.42, longitude: -75.69)
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: start.latitude, longitude: start.longitude, zoom: initial == nil ? 10 : 18)
        let map = GMSMapView(options: options)
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        if let c = center, context.coordinator.lastSet != c, context.coordinator.userMoved == false {
            map.animate(toLocation: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var center: Binding<GeoPoint?>
        var lastSet: GeoPoint?
        var userMoved = false
        init(center: Binding<GeoPoint?>) { self.center = center }
        func mapView(_ mapView: GMSMapView, willMove gesture: Bool) { if gesture { userMoved = true } }
        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            let p = GeoPoint(latitude: position.target.latitude, longitude: position.target.longitude)
            lastSet = p
            center.wrappedValue = p
            userMoved = false
        }
    }
}

struct ApplePinMap: View {
    @Binding var center: GeoPoint?
    var initial: GeoPoint?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position)
            .onMapCameraChange(frequency: .onEnd) { ctx in
                center = GeoPoint(latitude: ctx.region.center.latitude, longitude: ctx.region.center.longitude)
            }
            .onAppear {
                let p = initial ?? GeoPoint(latitude: 48.4284, longitude: -123.3656)
                position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), latitudinalMeters: 600, longitudinalMeters: 600))
                center = p
            }
            .onChange(of: center) { _, c in
                // Programmatic moves (e.g. "I'm at the delivery spot") recentre the map; user pans
                // already match the camera, so they are left alone.
                guard let c else { return }
                let current = position.region?.center
                if current == nil || abs(current!.latitude - c.latitude) > 0.0001 || abs(current!.longitude - c.longitude) > 0.0001 {
                    position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), latitudinalMeters: 300, longitudinalMeters: 300))
                }
            }
    }
}
