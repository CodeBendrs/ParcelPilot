import GoogleMaps
import MapKit
import ParcelPilotKit
import SwiftUI

/// Picks the map for the session: Google Maps for production (Google content is only ever drawn on a
/// Google map), Apple MapKit for demo/emulator sessions whose locations are synthetic.
struct RouteMapView: View {
    let snapshot: RouteSnapshot
    let planState: PlanTracker.PlanState
    @Binding var selectedStopID: StopID?
    var bottomInset: CGFloat
    var delivering = false
    var displayOrder: [StopID]? = nil
    var proposed = false
    @State private var fitID = UUID()
    @State private var driverPoint: GeoPoint?
    @State private var locationError: String?
    @Environment(AppServices.self) private var services

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let markers = displayMarkers
        ZStack {
        switch services.mapStyle {
        case .google:
            GoogleRouteMap(markers: markers, start: startPoint, polylines: polylines, selectedStopID: $selectedStopID, bottomInset: bottomInset, reduceMotion: reduceMotion, solid: isSolid, driverPoint: driverPoint, rightInset: delivering ? 72 : 0, currentStopID: delivering ? snapshot.nextStop()?.id : nil)
                .accessibilityLabel("Route map with \(markers.count) stops")
        case .apple:
            AppleRouteMap(markers: markers, start: startPoint, selectedStopID: $selectedStopID, bottomInset: bottomInset, solid: isSolid, driverPoint: driverPoint, delivering: delivering, currentStopID: delivering ? snapshot.nextStop()?.id : nil)
        case let .googleUnavailable(reason):
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(Theme.neutral).accessibilityHidden(true)
                Text("Map not configured").font(.headline)
                Text(reason).font(.subheadline).foregroundStyle(Theme.neutral).multilineTextAlignment(.center)
            }
            .padding(Theme.Space.xl)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        }
        .id(fitID)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("routeMap")
        .accessibilityLabel(mapAccessibilityLabel)
        .overlay(alignment: delivering ? .bottomLeading : .bottomTrailing) {
            Button {
                if delivering {
                    Task { do {
                        let coordinate = try await services.location.currentLocation()
                        driverPoint = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        selectedStopID = snapshot.nextStop()?.id
                        fitID = UUID()
                    } catch { locationError = error.localizedDescription } }
                } else { selectedStopID = nil; fitID = UUID() }
            } label: {
                Image(systemName: delivering ? "location.viewfinder" : "arrow.up.left.and.arrow.down.right")
                    .font(.title3).frame(width: 44, height: 44).background(Theme.panel, in: Circle())
            }
            .accessibilityLabel(delivering ? "Centre on my location" : "Show whole route")
            .padding(.horizontal, 12).padding(.bottom, 34)
        }
        .alert("Location unavailable", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) { Button("OK") {} } message: { Text(locationError ?? "") }
    }

    private var mapAccessibilityLabel: String {
        let summary = "Route map, \(snapshot.stops.count) stops"
        guard delivering else { return summary }
        guard let stop = snapshot.nextStop(), let index = snapshot.orderedStops.firstIndex(where: { $0.id == stop.id }) else {
            return summary + ", no current stop"
        }
        return summary + ", current stop \(index + 1)"
    }

    private var isSolid: Bool { if proposed { return true }; if displayOrder != nil { return false }; if case .current = planState { return true }; return false }
    private var displayMarkers: [MapMarkerModel] {
        var markers = MapMarkerModel.make(snapshot: snapshot)
        if delivering {
            markers = markers.map { marker in var marker = marker; if marker.id == snapshot.nextStop()?.id && marker.badge == .pending { marker.badge = .current }; return marker }
        }
        if let displayOrder {
            let positions = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element, $0.offset + 1) })
            markers = markers.map { marker in
                var marker = marker
                marker.number = positions[marker.id] ?? marker.number
                if proposed && positions[marker.id] != nil { marker.badge = .current }
                return marker
            }.sorted { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
        }
        return markers
    }

    private var startPoint: GeoPoint? {
        guard let l = snapshot.route.start?.located, l.isUsable(at: Date()) else { return nil }
        return l.point
    }

    private var polylines: [String] {
        if displayOrder == nil || proposed, case let .current(p) = planState, p.provider == .google { return p.polylines }
        return []
    }
}

struct MapMarkerModel: Identifiable, Equatable {
    var id: StopID
    var number: Int
    var point: GeoPoint
    var status: StopStatus
    var title: String
    var badge: StopBadgeState

    static func make(snapshot: RouteSnapshot, now: Date = Date()) -> [MapMarkerModel] {
        let ledger = snapshot.ledger
        return snapshot.orderedStops.enumerated().compactMap { index, stop in
            guard let located = stop.usableLocation(at: now) else { return nil }
            return MapMarkerModel(id: stop.id, number: index + 1, point: located.point, status: ledger.stopStatus(stop, packages: snapshot.packages), title: stop.address.streetLine ?? "Stop \(index + 1)", badge: StopBadgeState.make(stop: stop, snapshot: snapshot))
        }
    }
}

// MARK: - Google

struct GoogleRouteMap: UIViewRepresentable {
    var markers: [MapMarkerModel]
    var start: GeoPoint?
    var polylines: [String]
    @Binding var selectedStopID: StopID?
    var bottomInset: CGFloat
    var reduceMotion = false
    var solid = false
    var driverPoint: GeoPoint?
    var rightInset: CGFloat = 0
    var currentStopID: StopID?

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selectedStopID) }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: 48.4284, longitude: -123.3656, zoom: 11)
        let map = GMSMapView(options: options)
        map.delegate = context.coordinator
        map.settings.compassButton = true
        map.settings.myLocationButton = false
        map.isMyLocationEnabled = false
        map.accessibilityElementsHidden = false
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        map.padding = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: rightInset)
        let c = context.coordinator
        c.selected = $selectedStopID
        if c.lastMarkers != markers || c.lastSelected != selectedStopID || c.lastPolylines != polylines || c.lastDriverPoint != driverPoint || c.lastSolid != solid || c.lastCurrentStopID != currentStopID {
            map.clear()
            for m in markers {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude))
                marker.icon = MarkerIcon.image(number: m.number, status: m.status, selected: m.id == selectedStopID, badge: m.badge, current: m.id == currentStopID)
                marker.userData = m.id
                marker.title = "Stop \(m.number)"
                marker.snippet = m.title
                marker.zIndex = m.id == selectedStopID ? 10 : 1
                marker.map = map
            }
            if let start {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                marker.icon = MarkerIcon.start()
                marker.title = "Start"
                marker.map = map
            }
            if polylines.isEmpty {
                let path = GMSMutablePath()
                if let start { path.add(CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)) }
                for marker in markers { path.add(CLLocationCoordinate2D(latitude: marker.point.latitude, longitude: marker.point.longitude)) }
                let line = GMSPolyline(path: path)
                line.strokeWidth = 3
                line.strokeColor = UIColor(solid ? Theme.brand : Theme.neutral)
                if !solid {
                    line.spans = GMSStyleSpans(path, [GMSStrokeStyle.solidColor(UIColor(Theme.neutral)), GMSStrokeStyle.solidColor(.clear)], [40, 30], .rhumb)
                }
                line.map = map
            }
            for encoded in polylines {
                guard let path = GMSPath(fromEncodedPath: encoded) else { continue }
                let line = GMSPolyline(path: path)
                line.strokeWidth = 5
                line.strokeColor = UIColor(Theme.brand)
                line.map = map
            }
            if c.lastMarkers != markers || c.lastDriverPoint != driverPoint || c.lastCurrentStopID != currentStopID {
                var points = markers.map(\.point)
                if let currentStopID, let index = markers.firstIndex(where: { $0.id == currentStopID }) {
                    points = Array(markers[index...].prefix(3)).map(\.point)
                    if let driverPoint { points.append(driverPoint) }
                } else if let start { points.append(start) }
                var bounds = GMSCoordinateBounds()
                for point in points { bounds = bounds.includingCoordinate(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) }
                if bounds.isValid { if reduceMotion { map.moveCamera(GMSCameraUpdate.fit(bounds, withPadding: 48)) } else { map.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 48)) } }
            } else if let id = selectedStopID, id != c.lastSelected, let m = markers.first(where: { $0.id == id }) {
                if reduceMotion { map.moveCamera(GMSCameraUpdate.setTarget(CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude))) } else { map.animate(toLocation: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude)) }
            }
            if let driverPoint {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: driverPoint.latitude, longitude: driverPoint.longitude))
                marker.icon = UIImage(systemName: "location.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
                marker.title = "Your location"; marker.map = map
            }
            c.lastDriverPoint = driverPoint
            c.lastCurrentStopID = currentStopID
            c.lastSolid = solid
            c.lastMarkers = markers
            c.lastSelected = selectedStopID
            c.lastPolylines = polylines
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var selected: Binding<StopID?>
        var lastDriverPoint: GeoPoint?
        var lastCurrentStopID: StopID?
        var lastSolid = false
        var lastMarkers: [MapMarkerModel] = []
        var lastSelected: StopID?
        var lastPolylines: [String] = []
        init(selected: Binding<StopID?>) { self.selected = selected }

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            if let id = marker.userData as? String { selected.wrappedValue = id }
            return false
        }
    }
}

enum MarkerIcon {
    @MainActor static func image(number: Int, status: StopStatus, selected: Bool, badge: StopBadgeState? = nil, current: Bool = false) -> UIImage {
        let size: CGFloat = selected || current ? 40 : 32
        let state = badge ?? (status == .completed ? .delivered : status == .partial ? .partial : status == .skipped ? .skipped : .pending)
        let color = UIColor(state == .review ? Theme.pinPending : state.color)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
            color.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            UIColor(state == .review ? Theme.reviewPin : selected && !current ? Theme.brand : Theme.panel).setStroke()
            ctx.cgContext.setLineWidth(selected || current ? 3 : 2)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            let text = state == .delivered ? "✓" : state == .failed ? "✕" : state == .skipped ? "↷" : state == .partial ? "◐" : state == .excluded ? "−" : "\(number)"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.42, weight: .bold), .foregroundColor: UIColor(Theme.panel)]
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), withAttributes: attrs)
        }
    }

    @MainActor static func start() -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        return UIImage(systemName: "house.circle.fill", withConfiguration: config)?.withTintColor(UIColor(Theme.brand), renderingMode: .alwaysOriginal) ?? UIImage()
    }
}

// MARK: - Apple (demo / emulator synthetic data only)

struct AppleRouteMap: View {
    var markers: [MapMarkerModel]
    var start: GeoPoint?
    @Binding var selectedStopID: StopID?
    var bottomInset: CGFloat
    var solid = false
    var driverPoint: GeoPoint?
    var delivering = false
    var currentStopID: StopID?
    @State private var position: MapCameraPosition = .automatic

    @State private var viewSize: CGSize = .zero

    /// Frames every stop (and the start). MapKit fits `.rect` inside the safe area, which includes
    /// the panel padding, so this runs after layout (and again when the panel height changes).
    private func fit() {
        var points = markers.map(\.point)
        if delivering, let currentStopID, let index = markers.firstIndex(where: { $0.id == currentStopID }) {
            points = Array(markers[index...].prefix(3)).map(\.point)
            if let driverPoint { points.append(driverPoint) }
        } else if let start { points.append(start) }
        guard !points.isEmpty, viewSize.height > bottomInset else { return }
        let mapPoints = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let minX = mapPoints.map(\.x).min()!, maxX = mapPoints.map(\.x).max()!
        let minY = mapPoints.map(\.y).min()!, maxY = mapPoints.map(\.y).max()!
        let content = MKMapRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        position = .rect(content.insetBy(dx: -max(content.width * 0.12, 600), dy: -max(content.height * 0.12, 600)))
    }

    var body: some View {
        Map(position: $position, selection: $selectedStopID) {
            let coordinates = (start.map { [$0] } ?? []) + markers.map(\.point)
            MapPolyline(coordinates: coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                .stroke(solid ? Theme.brand : Theme.neutral, style: StrokeStyle(lineWidth: 3, dash: solid ? [] : [5, 6]))
            if let driverPoint {
                Annotation("Your location", coordinate: CLLocationCoordinate2D(latitude: driverPoint.latitude, longitude: driverPoint.longitude)) {
                    Image(systemName: "location.circle.fill").font(.title).foregroundStyle(Theme.brand, Theme.panel)
                }
            }
            if let start {
                Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)) {
                    Image(systemName: "house.circle.fill").font(.title).foregroundStyle(Theme.brand, .white)
                }
            }
            ForEach(markers) { m in
                Annotation("Stop \(m.number)", coordinate: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude)) {
                    StopBadge(number: m.number, state: m.badge, size: selectedStopID == m.id || m.id == currentStopID ? 40 : 30)
                        .overlay(Circle().stroke(selectedStopID == m.id && m.id != currentStopID ? Theme.brand : Theme.panel, lineWidth: selectedStopID == m.id || m.id == currentStopID ? 3 : 2))
                        .shadow(radius: 2)
                }
                .tag(m.id)
                .annotationTitles(.hidden)
            }
        }
        .mapControls { MapCompass() }
        .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: delivering ? 72 : 0).allowsHitTesting(false) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomInset).allowsHitTesting(false) }
        .overlay(alignment: .topLeading) {
            Text("Demo map · synthetic locations")
                .font(.caption2.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.trailing, 10)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let first = viewSize == .zero
            viewSize = size
            if first { fit() }
        }
        .onChange(of: markers) { _, _ in fit() }
        .onChange(of: driverPoint) { _, _ in fit() }
        .onChange(of: currentStopID) { _, _ in fit() }
        .onChange(of: selectedStopID) { _, id in
            if delivering, id == currentStopID {
                fit()
            } else if let m = markers.first(where: { $0.id == id }) {
                position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude), latitudinalMeters: 1500, longitudinalMeters: 1500))
            }
        }
    }
}
