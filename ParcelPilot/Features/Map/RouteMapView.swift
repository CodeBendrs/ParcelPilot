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
    @Environment(AppServices.self) private var services

    var body: some View {
        let markers = MapMarkerModel.make(snapshot: snapshot)
        switch services.mapStyle {
        case .google:
            GoogleRouteMap(markers: markers, start: startPoint, polylines: polylines, selectedStopID: $selectedStopID, bottomInset: bottomInset)
                .accessibilityLabel("Route map with \(markers.count) stops")
        case .apple:
            AppleRouteMap(markers: markers, start: startPoint, selectedStopID: $selectedStopID, bottomInset: bottomInset)
        case let .googleUnavailable(reason):
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Map not configured").font(.headline)
                Text(reason).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(Theme.Space.xl)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }

    private var startPoint: GeoPoint? {
        guard let l = snapshot.route.start?.located, l.isUsable(at: Date()) else { return nil }
        return l.point
    }

    private var polylines: [String] {
        if case let .current(p) = planState, p.provider == .google { return p.polylines }
        return []
    }
}

struct MapMarkerModel: Identifiable, Equatable {
    var id: StopID
    var number: Int
    var point: GeoPoint
    var status: StopStatus
    var title: String

    static func make(snapshot: RouteSnapshot, now: Date = Date()) -> [MapMarkerModel] {
        let ledger = snapshot.ledger
        return snapshot.orderedStops.enumerated().compactMap { index, stop in
            guard let located = stop.usableLocation(at: now) else { return nil }
            return MapMarkerModel(id: stop.id, number: index + 1, point: located.point, status: ledger.stopStatus(stop, packages: snapshot.packages), title: stop.address.streetLine ?? "Stop \(index + 1)")
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
        map.padding = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        let c = context.coordinator
        c.selected = $selectedStopID
        if c.lastMarkers != markers || c.lastSelected != selectedStopID || c.lastPolylines != polylines {
            map.clear()
            for m in markers {
                let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude))
                marker.icon = MarkerIcon.image(number: m.number, status: m.status, selected: m.id == selectedStopID)
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
            for encoded in polylines {
                guard let path = GMSPath(fromEncodedPath: encoded) else { continue }
                let line = GMSPolyline(path: path)
                line.strokeWidth = 5
                line.strokeColor = UIColor(Theme.brand)
                line.map = map
            }
            if c.lastMarkers.map(\.id) != markers.map(\.id) {
                var bounds = GMSCoordinateBounds()
                for m in markers { bounds = bounds.includingCoordinate(CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude)) }
                if let start { bounds = bounds.includingCoordinate(CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)) }
                if bounds.isValid { map.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 48)) }
            } else if let id = selectedStopID, id != c.lastSelected, let m = markers.first(where: { $0.id == id }) {
                map.animate(toLocation: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude))
            }
            c.lastMarkers = markers
            c.lastSelected = selectedStopID
            c.lastPolylines = polylines
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var selected: Binding<StopID?>
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
    @MainActor static func image(number: Int, status: StopStatus, selected: Bool) -> UIImage {
        let size: CGFloat = selected ? 40 : 32
        let color: UIColor = status == .completed ? UIColor(Theme.success) : (status == .skipped || status == .partial) ? UIColor(Theme.warning) : UIColor(Theme.brand)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
            color.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            UIColor.white.setStroke()
            ctx.cgContext.setLineWidth(selected ? 3 : 2)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            let text = status == .completed ? "✓" : "\(number)"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.42, weight: .bold), .foregroundColor: UIColor.white]
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), withAttributes: attrs)
        }
    }

    @MainActor static func start() -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        return UIImage(systemName: "house.circle.fill", withConfiguration: config)?.withTintColor(UIColor(Theme.teal), renderingMode: .alwaysOriginal) ?? UIImage()
    }
}

// MARK: - Apple (demo / emulator synthetic data only)

struct AppleRouteMap: View {
    var markers: [MapMarkerModel]
    var start: GeoPoint?
    @Binding var selectedStopID: StopID?
    var bottomInset: CGFloat
    @State private var position: MapCameraPosition = .automatic

    @State private var viewSize: CGSize = .zero

    /// Frames every stop (and the start). MapKit fits `.rect` inside the safe area, which includes
    /// the panel padding, so this runs after layout (and again when the panel height changes).
    private func fit() {
        var points = markers.map(\.point)
        if let start { points.append(start) }
        guard !points.isEmpty, viewSize.height > bottomInset else { return }
        let mapPoints = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let minX = mapPoints.map(\.x).min()!, maxX = mapPoints.map(\.x).max()!
        let minY = mapPoints.map(\.y).min()!, maxY = mapPoints.map(\.y).max()!
        let content = MKMapRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        position = .rect(content.insetBy(dx: -max(content.width * 0.12, 600), dy: -max(content.height * 0.12, 600)))
    }

    var body: some View {
        Map(position: $position, selection: $selectedStopID) {
            if let start {
                Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)) {
                    Image(systemName: "house.circle.fill").font(.title).foregroundStyle(Theme.teal, .white)
                }
            }
            ForEach(markers) { m in
                Annotation("Stop \(m.number)", coordinate: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude)) {
                    StopNumberView(number: m.number, status: m.status, size: selectedStopID == m.id ? 40 : 30)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 2)
                }
                .tag(m.id)
                .annotationTitles(.hidden)
            }
        }
        .mapControls { MapCompass() }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomInset).allowsHitTesting(false) }
        .overlay(alignment: .bottomTrailing) {
            Text("Demo map · synthetic locations")
                .font(.caption2.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.trailing, 10)
                .padding(.bottom, bottomInset + 8)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let first = viewSize == .zero
            viewSize = size
            if first { fit() }
        }
        .onChange(of: markers.map(\.id)) { _, _ in fit() }
        .onChange(of: selectedStopID) { _, id in
            if let m = markers.first(where: { $0.id == id }) {
                position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: m.point.latitude, longitude: m.point.longitude), latitudinalMeters: 1500, longitudinalMeters: 1500))
            }
        }
    }
}
