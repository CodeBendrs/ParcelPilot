import ParcelPilotKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationStack {
            let finished = services.store.finishedRoutes.sorted { ($0.completedAt ?? $0.archivedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.archivedAt ?? $1.updatedAt) }
            List {
                if finished.isEmpty {
                    StateMessageView(symbol: "clock.arrow.circlepath", title: "No finished routes", message: "Routes you finish or archive appear here with their delivery results.")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(finished) { route in
                        NavigationLink(value: route.id) { HistoryRow(route: route) }
                            .accessibilityIdentifier("historyRow")
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: RouteID.self) { id in
                if let route = services.store.routes.first(where: { $0.id == id }) { RouteSummaryView(route: route) }
            }
        }
    }
}

struct HistoryRow: View {
    var route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(route.name).font(.headline)
                Spacer()
                StatusBadge(text: route.status.label, symbol: route.status == .completed ? "flag.checkered" : "archivebox", tone: .neutral, compact: true)
            }
            Text(route.serviceDate).font(.subheadline).foregroundStyle(.secondary)
            if let s = route.summary {
                Text("\(s.delivered) delivered · \(s.failed) failed · \(s.skipped) skipped").font(.subheadline)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct RouteSummaryView: View {
    let route: Route
    @Environment(AppServices.self) private var services
    @State private var snapshot: RouteSnapshot?
    @State private var loading = true

    var body: some View {
        let summary = snapshot?.summary() ?? route.summary ?? RouteSummary()
        List {
            Section("Results") {
                LabeledContent("Delivered", value: "\(summary.delivered)")
                LabeledContent("Failed", value: "\(summary.failed)")
                LabeledContent("Skipped (not delivered)", value: "\(summary.skipped)")
                LabeledContent("Excluded", value: "\(summary.excluded)")
                if summary.pending > 0 { LabeledContent("Never attempted", value: "\(summary.pending)") }
                LabeledContent("Stops / packages", value: "\(summary.stopCount) / \(summary.packageCount)")
            }
            Section {
                if let first = summary.firstOutcomeAt, let last = summary.lastOutcomeAt {
                    LabeledContent("First outcome", value: DisplayFormat.dateTime(first, timeZone: route.timeZone))
                    LabeledContent("Last outcome", value: DisplayFormat.dateTime(last, timeZone: route.timeZone))
                    LabeledContent("Delivery duration", value: DisplayFormat.duration(seconds: Int(last.timeIntervalSince(first))))
                } else {
                    Text("No outcomes were recorded.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Time")
            } footer: {
                Text("Measured from your recorded outcomes (actual times), not from planned arrival times.")
            }
            Section {
                if let d = route.plannedDistance, d.expiresAt > Date() {
                    LabeledContent("Planned road distance", value: DisplayFormat.distance(meters: d.meters, unit: services.settings.settings.distanceUnit))
                    ProvenanceText(text: "Source: \(d.provider.displayName), calculated \(DisplayFormat.dateTime(d.calculatedAt, timeZone: route.timeZone)). Planned, not driven — kept for 24 hours under the provider's terms.")
                } else {
                    Text("Distance not available").foregroundStyle(.secondary)
                    ProvenanceText(text: "ParcelPilot doesn't track your driving in the background, and provider distance estimates are kept for only 24 hours.")
                }
            } header: {
                Text("Distance")
            }
            if let snapshot {
                let failed = snapshot.packages.filter { if case .failed = snapshot.ledger.status(of: $0.id) { return true }; return false }
                if !failed.isEmpty {
                    Section("Failed deliveries") {
                        ForEach(failed) { p in
                            let stop = snapshot.stops.first { $0.id == p.stopID }
                            VStack(alignment: .leading) {
                                Text([stop?.address.streetLine, stop?.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.weight(.semibold))
                                Text(snapshot.ledger.status(of: p.id).label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if loading {
                ProgressView()
            }
            Section {
                Button("Reopen route") { services.store.resume(route) }
                Button("Duplicate as new route") { Task { _ = try? await services.store.duplicate(route) } }
            }
        }
        .navigationTitle(route.name)
        .task {
            snapshot = try? await services.store.backend.fetchRoute(route.id)
            loading = false
        }
    }
}
