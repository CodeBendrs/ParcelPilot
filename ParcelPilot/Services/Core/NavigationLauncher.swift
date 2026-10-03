import Foundation
import Observation
import ParcelPilotKit
import UIKit

/// Opens Apple Maps or Google Maps for a stop with the driver-confirmed building address and
/// remembers the hand-off, so the app can show the same stop when the driver returns. Returning from
/// a maps app never records a delivery.
@MainActor
@Observable
final class NavigationLauncher {
    struct Handoff: Equatable {
        var routeID: RouteID
        var stopID: StopID
        var at: Date
        var app: NavigationApp
    }

    private(set) var lastHandoff: Handoff?

    var googleMapsInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
    }

    enum LaunchError: LocalizedError {
        case noStreetAddress
        case couldNotOpen
        var errorDescription: String? {
            switch self {
            case .noStreetAddress: return "This stop has no street address (PO box, general delivery or rural route). Use the notes or a pinned location instead."
            case .couldNotOpen: return "The maps app couldn't be opened."
            }
        }
    }

    func open(stop: Stop, routeID: RouteID, using app: NavigationApp) async throws {
        let request: NavigationHandoff.Request
        switch app {
        case .googleMaps:
            request = try NavigationHandoff.googleMaps(address: stop.address, placeID: stop.resolution?.provider == .google ? stop.resolution?.placeID : nil, appInstalled: googleMapsInstalled).mapError { _ in LaunchError.noStreetAddress }.get()
        case .appleMaps, .ask:
            request = try NavigationHandoff.appleMaps(address: stop.address).mapError { _ in LaunchError.noStreetAddress }.get()
        }
        let opened = await UIApplication.shared.open(request.url)
        guard opened else { throw LaunchError.couldNotOpen }
        lastHandoff = Handoff(routeID: routeID, stopID: stop.id, at: Date(), app: app)
    }

    func clearHandoff() { lastHandoff = nil }
}
