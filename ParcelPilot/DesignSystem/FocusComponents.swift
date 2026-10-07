import ParcelPilotKit
import SwiftUI

struct UnitTile: View {
    var value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("UNIT").font(.footnote.bold())
            Text(value).font(.unit).fixedSize(horizontal: true, vertical: false)
        }
        .padding(12)
        .foregroundStyle(Theme.onBrand)
        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unit \(value)")
    }
}

struct LocationCodeTile: View {
    var location: String?
    static func code(for location: String?) -> String {
        guard let location, !location.isEmpty else { return "—" }
        let words = location.uppercased().split { !$0.isLetter && !$0.isNumber }
        let meaningful = words.filter { !["SHELF", "BIN", "IN", "THE", "VEHICLE"].contains(String($0)) }
        return String(meaningful.map { word in word.allSatisfy(\.isNumber) || word.count <= 2 ? String(word) : String(word.prefix(1)) }.joined().prefix(3))
    }
    var body: some View {
        Text(Self.code(for: location)).font(.locationCode)
            .padding(12).background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

enum StopBadgeState: Equatable {
    case pending, current, delivered, failed, skipped, partial, review, excluded
    var color: Color {
        switch self {
        case .pending: Theme.pinPending
        case .current: Theme.brand
        case .delivered: Theme.success
        case .failed: Theme.danger
        case .skipped, .partial: Theme.warning
        case .review: Theme.reviewPin
        case .excluded: Theme.neutral
        }
    }
    var symbol: String? {
        switch self {
        case .delivered: "checkmark"
        case .failed: "xmark"
        case .skipped: "arrow.uturn.forward"
        case .partial: "circle.lefthalf.filled"
        case .excluded: "minus"
        default: nil
        }
    }
    static func label(stop: Stop, snapshot: RouteSnapshot) -> String {
        switch make(stop: stop, snapshot: snapshot) {
        case .delivered: return snapshot.tasks.contains { $0.stopID == stop.id } ? "completed" : "delivered"
        case .failed: return "failed"
        case .excluded: return "excluded"
        case .skipped: return "skipped"
        case .review: return stop.addressStatus.label
        case .partial:
            if snapshot.tasks.contains(where: { $0.stopID == stop.id }) {
                let ledger = snapshot.workLedger
                let required = ledger.tasks(at: stop.id).filter(\.required)
                let completed = required.filter { ledger.status(of: $0.id).isSuccessful }.count
                return "\(completed) of \(required.count) completed successfully"
            }
            let packages = snapshot.packages(for: stop.id)
            let delivered = packages.filter { if case .delivered = snapshot.ledger.status(of: $0.id) { true } else { false } }.count
            return "\(delivered) of \(packages.count) delivered"
        default: return "to do"
        }
    }
    static func make(stop: Stop, snapshot: RouteSnapshot, current: Bool = false) -> Self {
        let ledger = snapshot.workLedger
        let statuses = ledger.tasks(at: stop.id).filter(\.required).map { ledger.status(of: $0.id) }
        if !statuses.isEmpty && statuses.allSatisfy({ if case .failed = $0 { true } else { false } }) { return .failed }
        if !statuses.isEmpty && statuses.allSatisfy({ if case .excluded = $0 { true } else { false } }) { return .excluded }
        switch ledger.stopStatus(stop) {
        case .completed:
            if statuses.contains(where: { if case .failed = $0 { true } else { false } }) { return .failed }
            if statuses.contains(where: { if case .excluded = $0 { true } else { false } }) { return .partial }
            return .delivered
        case .partial: return .partial
        case .skipped: return .skipped
        case .empty: return .excluded
        case .pending:
            if current { return .current }
            return [.needsReview, .unresolvable, .pendingVerification].contains(stop.addressStatus) ? .review : .pending
        }
    }
}

struct StopBadge: View {
    var number: Int
    var state: StopBadgeState
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            Circle().fill(state == .review ? Theme.pinPending : state.color)
            if let symbol = state.symbol {
                Image(systemName: symbol).font(.footnote.bold())
            } else {
                Text("\(number)").font(.footnote.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(Theme.panel)
        .frame(width: size, height: size)
        .overlay(Circle().stroke(state == .review ? Theme.reviewPin : state == .current ? Theme.onBrand : Theme.panel, style: StrokeStyle(lineWidth: state == .current ? 3 : 2, dash: state == .excluded ? [3, 2] : [])))
        .accessibilityHidden(true)
    }
}

struct StatusLine: View {
    var snapshot: RouteSnapshot
    var body: some View {
        let summary = snapshot.summary()
        let states = snapshot.stops.map { StopBadgeState.make(stop: $0, snapshot: snapshot) }
        FlowRow(spacing: 8) {
            Label("\(states.filter { $0 == .delivered }.count) \(snapshot.tasks.isEmpty ? "delivered" : "completed")", systemImage: "checkmark").foregroundStyle(Theme.success)
            Label("\(states.filter { $0 == .failed }.count) failed", systemImage: "xmark").foregroundStyle(Theme.danger)
            if snapshot.workSummary.deferred > 0 {
                Label("\(states.filter { $0 == .skipped }.count) skipped", systemImage: "arrow.uturn.forward").foregroundStyle(Theme.warning)
            }
            Text(snapshot.tasks.isEmpty
                 ? "\(summary.delivered + summary.failed + summary.excluded) of \(summary.packageCount) packages"
                 : "\(snapshot.workSummary.handled) of \(snapshot.workSummary.required) required work items handled").foregroundStyle(Theme.neutral)
        }
        .font(.subheadline.weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityElement(children: .combine)
    }
}

struct SyncStateRow: View {
    @Environment(AppServices.self) private var services
    @State private var details = false
    var body: some View {
        let failed = services.journal?.failed.count ?? 0
        let keys = services.store.currentPendingKeys.union(services.store.pendingRouteKeys)
        let outcomes = keys.filter { $0.contains("/outcomes/") }.count
        let pending = keys.count + services.photos.pending.count
        if let issue = services.store.persistenceIssue {
            Banner(symbol: "exclamationmark.triangle", text: issue, tone: .danger)
                .accessibilityIdentifier("localPersistenceIssue")
        }
        if let issue = services.photos.storageIssue {
            Banner(symbol: "photo.badge.exclamationmark", text: issue, tone: .danger)
        }
        if !services.store.currentReadIssues.isEmpty || services.store.current?.hasUnsupportedRequiredWork == true {
            Banner(symbol: "exclamationmark.triangle", text: "Some work couldn't be read safely. Planning and route close-out are blocked until it can be read with a compatible app.", tone: .danger)
        }
        if failed > 0 || !services.connectivity.isOnline || (!services.mode.isDemo && pending > 0) {
            Button { details = true } label: {
                HStack {
                    Label(failed > 0 ? "\(failed) change\(failed == 1 ? "" : "s") couldn't sync · Review" : !services.connectivity.isOnline ? (services.mode.isDemo ? "Offline · Demo data stays on this iPhone" : "Offline · \(outcomes) outcome\(outcomes == 1 ? "" : "s") waiting to sync") : "Syncing \(pending)…", systemImage: failed > 0 ? "exclamationmark.icloud" : !services.connectivity.isOnline ? "icloud.slash" : "arrow.triangle.2.circlepath")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                .foregroundStyle(failed > 0 ? Theme.danger : !services.connectivity.isOnline ? Theme.warning : Theme.neutral)
            }
            .accessibilityIdentifier("syncStateRow")
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
            .sheet(isPresented: $details) { SyncStatusView() }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12).foregroundStyle(Theme.onBrand)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct ActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    var fill: Color = Theme.fill
    var height: CGFloat = 50
    var radius: CGFloat = 14
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(tint).background(fill, in: RoundedRectangle(cornerRadius: radius))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
