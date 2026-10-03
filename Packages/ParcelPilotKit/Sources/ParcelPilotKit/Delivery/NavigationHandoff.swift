import Foundation

/// Builds hand-off URLs for external navigation apps.
///
/// * The destination is the **driver-confirmed street address text**, building level (the unit stays
///   on the stop card). Apple Maps resolves it independently; it never receives Google coordinates or
///   place IDs.
/// * Google Maps may additionally receive the Google place ID (Google content shown in a Google product).
/// * Non-civic addresses (PO box, general delivery) have no drivable street address; the caller must
///   ask the driver before navigating to the municipality only.
public enum NavigationHandoff {
    public enum Target: String, Sendable { case appleMaps, googleMapsApp, googleMapsWeb }

    public struct Request: Equatable, Sendable {
        public var target: Target
        public var url: URL
        public var query: String
    }

    public enum Problem: Error, Equatable, Sendable {
        /// No civic street address; navigation would go to an area, not a building.
        case noStreetAddress
    }

    public static func destinationQuery(for address: PostalAddress) -> Result<String, Problem> {
        guard address.civicNumber?.isEmpty == false, address.streetName?.isEmpty == false else { return .failure(.noStreetAddress) }
        return .success(address.buildingQuery)
    }

    public static func appleMaps(address: PostalAddress) -> Result<Request, Problem> {
        destinationQuery(for: address).map { query in
            var c = URLComponents(string: "https://maps.apple.com/")!
            c.queryItems = [URLQueryItem(name: "daddr", value: query), URLQueryItem(name: "dirflg", value: "d")]
            return Request(target: .appleMaps, url: c.url!, query: query)
        }
    }

    /// - Parameter appInstalled: whether `comgooglemaps://` can be opened.
    public static func googleMaps(address: PostalAddress, placeID: String?, appInstalled: Bool) -> Result<Request, Problem> {
        destinationQuery(for: address).map { query in
            if appInstalled {
                var c = URLComponents()
                c.scheme = "comgooglemaps"
                c.host = ""
                c.queryItems = [URLQueryItem(name: "daddr", value: query), URLQueryItem(name: "directionsmode", value: "driving")]
                return Request(target: .googleMapsApp, url: c.url!, query: query)
            }
            var c = URLComponents(string: "https://www.google.com/maps/dir/")!
            var items = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: query), URLQueryItem(name: "travelmode", value: "driving")]
            if let placeID { items.append(URLQueryItem(name: "destination_place_id", value: placeID)) }
            c.queryItems = items
            return Request(target: .googleMapsWeb, url: c.url!, query: query)
        }
    }
}
