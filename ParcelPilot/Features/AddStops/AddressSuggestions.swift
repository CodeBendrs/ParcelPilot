import ParcelPilotKit
import SwiftUI

/// Google address suggestions while the driver types (Canada, street addresses only). Requests are
/// debounced so typing one address costs a few calls; the server enforces daily and monthly caps.
/// Demo mode has no address provider and shows none.
@MainActor
@Observable
final class AddressSuggestionsModel {
    private(set) var suggestions: [AddressSuggestion] = []
    /// Why suggestions aren't available (quota reached, not configured). Typing still works.
    private(set) var notice: String?
    /// Place ID being resolved after a tap.
    private(set) var resolving: String?
    private var sessionToken = UUID().uuidString
    private var pending: Task<Void, Never>?

    static let minimumLength = 4
    static let debounce: Duration = .milliseconds(350)

    func queryChanged(_ text: String, resolver: AddressResolver, near: GeoPoint?) {
        pending?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolver.provider != .demo, query.count >= Self.minimumLength, !query.contains(where: \.isNewline) else {
            suggestions = []
            return
        }
        let token = sessionToken
        pending = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let result = try await resolver.suggest(query, sessionToken: token, near: near)
                guard !Task.isCancelled else { return }
                suggestions = result
                notice = nil
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
                let serviceError = error as? ServiceError
                notice = serviceError?.isOffline == true ? nil : (serviceError ?? .unavailable(error.localizedDescription)).localizedDescription
            }
        }
    }

    /// Resolves the picked suggestion to a checked location and starts a new suggestion session.
    func pick(_ suggestion: AddressSuggestion, resolver: AddressResolver) async throws -> ResolveResponse {
        pending?.cancel()
        resolving = suggestion.placeID
        defer { resolving = nil }
        let response = try await resolver.resolve(.placeID(suggestion.placeID))
        sessionToken = UUID().uuidString
        suggestions = []
        return response
    }

    /// The route's start, or its first located stop, so nearby addresses rank first. No GPS prompt.
    static func bias(for snapshot: RouteSnapshot?) -> GeoPoint? {
        guard let snapshot else { return nil }
        return snapshot.route.start?.located?.point ?? snapshot.stops.lazy.compactMap { $0.resolution?.located?.point }.first
    }
}

/// Suggestion rows for a `List`/`Form`, with the Google attribution and any notice.
struct AddressSuggestionsSection: View {
    let model: AddressSuggestionsModel
    var onPick: (AddressSuggestion) -> Void

    var body: some View {
        if !model.suggestions.isEmpty {
            Section {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button { onPick(suggestion) } label: { row(suggestion) }
                        .disabled(model.resolving != nil)
                        .accessibilityIdentifier("suggestion.\(index)")
                }
            } footer: {
                Text("Suggestions from Google Maps")
            }
        } else if let notice = model.notice {
            Section { Banner(symbol: "exclamationmark.triangle", text: "Address suggestions aren't available: \(notice)", tone: .warning) }
        }
    }

    private func row(_ s: AddressSuggestion) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "mappin.circle").foregroundStyle(Theme.brand).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.primaryText).foregroundStyle(.primary)
                if let secondary = s.secondaryText {
                    Text(secondary).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.resolving == s.placeID { ProgressView() }
        }
        .frame(minHeight: Theme.minTouch)
        .contentShape(Rectangle())
    }
}
