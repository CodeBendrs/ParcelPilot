import ParcelPilotKit
import SwiftUI

struct OptimizeSheet: View {
    let snapshot: RouteSnapshot
    enum OriginChoice: Hashable { case routeStart, currentLocation, stop(StopID) }
    var defaultOrigin: OriginChoice
    var keepOrder: () -> Void = {}

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var origin: OriginChoice = .routeStart
    @State private var fixedNext: StopID?
    @State private var computeBaseline = false
    @State private var considerTraffic = true
    @State private var requestID: String?
    @State private var job: OptimizationJob?
    @State private var token: ListenerToken?
    @State private var starting = false
    @State private var error: ServiceError?
    @State private var started = Date()

    private var live: RouteSnapshot { services.store.current?.route.id == snapshot.route.id ? services.store.current! : snapshot }
    private var isDelivering: Bool { live.route.status == .active }
    private var unreadableWork: Bool { !services.store.currentReadIssues.isEmpty || live.hasUnsupportedRequiredWork }

    var body: some View {
        NavigationStack {
            List {
                if let job {
                    jobSection(job)
                } else {
                    optionsSections
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let job, [.succeeded, .infeasible].contains(job.status), let proposal = job.proposal {
                    let verdict = ProposalValidator.validate(proposal, against: live, now: Date(), demoMode: services.verifier.allowsSynthetic)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing changes until you choose.").font(.footnote).foregroundStyle(Theme.neutral)
                        let footerLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                        footerLayout {
                            Button("Keep my order") { keepOrder(); dismiss() }
                                .buttonStyle(ActionButtonStyle(height: 64))
                                .accessibilityIdentifier("keepCurrentOrder")
                            Button { apply(proposal) } label: { Label("Use this order", systemImage: "checkmark") }
                                .buttonStyle(ActionButtonStyle(tint: Theme.onBrand, fill: Theme.brand, height: 64))
                                .disabled(verdict != .valid || unreadableWork).accessibilityIdentifier("applyPlan")
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .padding(16).background(Theme.panel)
                }
            }
            .navigationTitle(job?.proposal != nil ? "Proposed order" : isDelivering || defaultOrigin == .currentLocation ? "Re-plan remaining" : "Optimize route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                origin = defaultOrigin == .currentLocation ? .currentLocation : (live.route.start == nil ? .currentLocation : .routeStart)
                considerTraffic = live.route.considerTraffic
            }
        }
    }

    // MARK: Options

    @ViewBuilder private var optionsSections: some View {
        let eligibility = Eligibility.evaluate(live, now: Date(), demoMode: services.verifier.allowsSynthetic)
        Section {
            Picker("Start from", selection: $origin) {
                if live.route.start != nil { Text("Route start").tag(OriginChoice.routeStart) }
                Text("My current location").tag(OriginChoice.currentLocation)
                ForEach(live.orderedStops.filter { $0.usableLocation(at: Date()) != nil }) { s in
                    Text("At \(s.address.streetLine ?? "stop")").tag(OriginChoice.stop(s.id))
                }
            }
            Picker("Next stop", selection: $fixedNext) {
                Text("Let the optimizer choose").tag(StopID?.none)
                ForEach(eligibility.eligible) { s in Text(s.address.streetLine ?? "Stop").tag(StopID?.some(s.id)) }
            }
            if services.optimizer.provider == .google {
                Toggle("Traffic-aware estimates", isOn: $considerTraffic)
                Toggle("Compare with my current order", isOn: $computeBaseline)
            }
        } header: {
            Text("Options")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if origin == .currentLocation { Text("Your location is read once, now, and used only for this calculation.") }
                if computeBaseline { Text("Comparing makes a second optimization request so savings can be shown honestly.") }
                if services.optimizer.provider == .demo { Text("Demo mode: straight-line estimate at an assumed average speed, not road travel times.") }
                if services.optimizer.provider == .emulatorFake { Text("Emulator test provider: synthetic results for local testing.") }
            }
        }

        Section("What gets planned") {
            if unreadableWork {
                Banner(symbol: "exclamationmark.triangle", text: "Some work couldn't be read safely. Planning is blocked until the route can be read with a compatible app.", tone: .danger)
            }
            LabeledContent("Stops to plan", value: "\(eligibility.eligible.count)")
            let grouped = Dictionary(grouping: eligibility.excluded, by: \.reason)
            ForEach(grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { reason in
                if reason != .completed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(grouped[reason]!.count) not included").font(.subheadline.weight(.semibold))
                        Text(ExcludedStop(stopID: "", reason: reason).explanation).font(.caption).foregroundStyle(Theme.neutral)
                    }
                }
            }
            if let completed = grouped[.completed] { LabeledContent("Already handled (kept as is)", value: "\(completed.count)") }
            if eligibility.eligible.count > RouteLimits.maxEligibleStopsPerOptimization {
                Banner(symbol: "exclamationmark.triangle", text: "Up to \(RouteLimits.maxEligibleStopsPerOptimization) stops can be optimized at once. Split this route.", tone: .danger)
            }
        }

        if let error {
            Section { Banner(symbol: error.isOffline ? "icloud.slash" : "exclamationmark.triangle.fill", text: error.localizedDescription, tone: error.isOffline ? .warning : .danger) }
        }

        Section {
            Button {
                Task { await start() }
            } label: {
                if starting { ProgressView().frame(maxWidth: .infinity) } else { Label("Calculate", systemImage: "wand.and.stars") }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(unreadableWork || !services.connectivity.isOnline || starting || eligibility.eligible.isEmpty || eligibility.eligible.count > RouteLimits.maxEligibleStopsPerOptimization)
            .accessibilityIdentifier("calculate")
            .listRowBackground(Color.clear)
            if !services.connectivity.isOnline { Text("Needs a connection").font(.footnote).foregroundStyle(Theme.warning) }
        }
    }

    // MARK: Job

    @ViewBuilder private func jobSection(_ job: OptimizationJob) -> some View {
        switch job.status {
        case .queued, .running:
            Section {
                VStack(spacing: Theme.Space.m) {
                    ProgressView()
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("Calculating… \(Int(ctx.date.timeIntervalSince(started))) s").font(.headline.monospacedDigit())
                    }
                    Text(services.mode.isDemo ? "Running on this iPhone." : "The calculation runs on the server. You can close this screen — the result is saved and your stops stay as they are until you apply it.")
                        .font(.subheadline).foregroundStyle(Theme.neutral).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
            }
        case .succeeded, .infeasible:
            if let proposal = job.proposal {
                ProposalPreview(proposal: proposal, snapshot: live, recalculate: { reset() })
            } else {
                Section { ProgressView("Loading result…") }
            }
        case .stale:
            Section {
                StateMessageView(symbol: "arrow.triangle.2.circlepath", title: "The route changed", message: job.error?.message ?? "Your edits were kept. Recalculate to include them.", actions: [.init(title: "Recalculate", symbol: "arrow.clockwise") { reset() }], tone: .warning)
            }
        case .failed, .cancelled:
            Section {
                StateMessageView(symbol: "exclamationmark.triangle", title: "Couldn't optimize", message: (job.error?.message ?? "The optimization failed.") + (job.error?.suggestions.isEmpty == false ? "\n\n" + job.error!.suggestions.joined(separator: "\n") : ""), actions: [.init(title: "Try again", symbol: "arrow.clockwise") { reset() }], tone: .danger)
            }
        }
    }

    private func reset() {
        token?.remove()
        job = nil
        requestID = nil
        error = nil
    }

    private func start() async {
        guard !unreadableWork else { error = .invalid("Some required work couldn't be read safely."); return }
        starting = true
        error = nil
        defer { starting = false }
        let id = requestID ?? StableID.make()
        requestID = id
        var resolvedOrigin: OptimizationOrigin
        switch origin {
        case .routeStart: resolvedOrigin = .routeStart
        case let .stop(sid): resolvedOrigin = .stop(sid)
        case .currentLocation:
            do {
                let c = try await services.location.currentLocation()
                resolvedOrigin = .currentLocation(GeoPoint(latitude: c.latitude, longitude: c.longitude))
            } catch {
                self.error = .permission(error.localizedDescription)
                return
            }
        }
        let options = OptimizationOptions(origin: resolvedOrigin, fixedNextStopID: fixedNext, computeBaseline: computeBaseline, considerTraffic: considerTraffic, departNow: isDelivering)
        started = Date()
        do {
            let initial = try await services.optimizer.start(snapshot: live, options: options, requestID: id)
            job = initial
            token = services.optimizer.observe(jobID: initial.id) { update in
                if let update { job = update }
            }
        } catch let e as ServiceError {
            error = e
            if case .rejected = e { requestID = nil }
            if case .invalid = e { requestID = nil }
            if case .quotaExceeded = e { requestID = nil }
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    private func apply(_ proposal: OptimizationProposal) {
        guard services.store.apply(proposal, to: live).isCommitted else {
            error = .unavailable(services.store.persistenceIssue ?? "The route order couldn't be saved on this iPhone. Try again.")
            return
        }
        Haptics.success()
        toasts.show("New order applied", symbol: "wand.and.stars", tone: .success)
        dismiss()
    }
}

struct ProposalPreview: View {
    let proposal: OptimizationProposal
    let snapshot: RouteSnapshot
    var recalculate: () -> Void
    @Environment(AppServices.self) private var services
    @State private var proposed = true
    @State private var selectedStopID: StopID?

    var body: some View {
        let verdict = ProposalValidator.validate(proposal, against: snapshot, now: Date(), demoMode: services.verifier.allowsSynthetic)
        let tz = snapshot.route.timeZone
        let unit = services.settings.settings.distanceUnit
        Section {
            RouteMapView(snapshot: snapshot, planState: .current(proposal), selectedStopID: $selectedStopID, bottomInset: 0, displayOrder: proposed ? ProposalValidator.sequencesAfterApplying(proposal, to: snapshot).sorted { $0.value < $1.value }.map(\.key) : snapshot.orderedStops.map(\.id), proposed: proposed)
                .frame(height: 270)
                .overlay(alignment: .topLeading) {
                    Picker("Route overlay", selection: $proposed) {
                        Text("Proposed").tag(true)
                        Text("Current").tag(false)
                    }
                    .pickerStyle(.segmented).frame(width: 240).padding(12)
                    .accessibilityIdentifier("proposalMapToggle")
                }
                .listRowInsets(EdgeInsets())
        }
        Section {
            switch verdict {
            case .valid: EmptyView()
            case let .stale(reason):
                Banner(symbol: "arrow.triangle.2.circlepath", text: reason, tone: .warning, actionTitle: "Recalculate", action: recalculate)
            case let .invalid(reason):
                Banner(symbol: "xmark.octagon", text: "This result can't be used: \(reason)", tone: .danger, actionTitle: "Recalculate", action: recalculate)
            }
            if let m = proposal.metrics {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.l) {
                        Metric(title: "Duration", value: DisplayFormat.duration(seconds: m.totalSeconds))
                        Metric(title: "Distance", value: DisplayFormat.distance(meters: m.travelMeters, unit: unit))
                        Metric(title: "Finish", value: DisplayFormat.time(m.routeEnd, timeZone: tz))
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Metric(title: "Duration", value: DisplayFormat.duration(seconds: m.totalSeconds))
                        Metric(title: "Distance", value: DisplayFormat.distance(meters: m.travelMeters, unit: unit))
                        Metric(title: "Finish", value: DisplayFormat.time(m.routeEnd, timeZone: tz))
                    }
                }
                let parts = ["\(DisplayFormat.duration(seconds: m.serviceSeconds)) at stops"]
                    + (m.waitSeconds >= 60 ? ["\(DisplayFormat.duration(seconds: m.waitSeconds)) waiting for delivery windows"] : [])
                    + (m.breakSeconds > 0 ? ["\(DisplayFormat.duration(seconds: m.breakSeconds)) break"] : [])
                Text("Includes " + parts.joined(separator: ", ") + ".").font(.caption).foregroundStyle(Theme.neutral)
                if let minute = snapshot.route.latestArrivalMinute {
                    Label("\(snapshot.route.returnToStart ? "Back by" : "Arrive by") \(WallClock.label(minute)) · includes the drive to \(snapshot.route.returnToStart ? "Start" : "End").", systemImage: "clock")
                        .font(.subheadline)
                        .accessibilityIdentifier("latestArrivalSummary")
                }
            }
            if let savings = proposal.savings {
                Label(savings.seconds >= 0 ? "About \(DisplayFormat.duration(seconds: savings.seconds)) and \(DisplayFormat.distance(meters: max(0, savings.meters), unit: unit)) less than your current order (same conditions)." : "Your current order is already as fast as this one.", systemImage: "chart.line.downtrend.xyaxis")
                    .font(.subheadline)
            }
            ProvenanceText(text: "\(proposal.provider.displayName). \(proposal.trafficLabel). Calculated \(DisplayFormat.dateTime(proposal.calculatedAt, timeZone: tz)). Estimates — not a guaranteed best route.")
        } header: {
            Text(proposal.status == .feasible ? "Proposed plan" : "Partial plan — action needed")
        }

        if !proposal.unassigned.isEmpty {
            Section {
                ForEach(proposal.unassigned, id: \.stopID) { u in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(stopName(u.stopID)).font(.headline)
                        Text(u.issue.message).font(.subheadline)
                        ForEach(u.issue.suggestions, id: \.self) { s in Label(s, systemImage: "lightbulb").font(.caption).foregroundStyle(Theme.neutral) }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("\(proposal.unassigned.count) stop\(proposal.unassigned.count == 1 ? "" : "s") can't be scheduled")
            } footer: {
                Text("These stops and their packages stay on your route. Change the constraints above, or apply this order and handle them yourself.")
            }
        }

        let excluded = proposal.excluded.filter { $0.reason != .completed }
        if !excluded.isEmpty {
            Section("Not placed in this plan") {
                ForEach(excluded, id: \.stopID) { stop in
                    Banner(symbol: "exclamationmark.triangle", text: "\(stopName(stop.stopID)) · \(stop.explanation)", tone: .warning)
                }
            }
        }
        if !proposal.warnings.isEmpty {
            Section("Notes") { ForEach(proposal.warnings, id: \.self) { Text($0).font(.subheadline) } }
        }

        let changes = ProposalValidator.positionChanges(proposal, snapshot: snapshot)
        Section("\(changes.count) STOPS CHANGE POSITION") {
            if changes.isEmpty {
                Text("The proposed order matches your current order.").font(.subheadline).foregroundStyle(Theme.neutral)
            }
            ForEach(changes.prefix(60), id: \.stopID) { change in
                HStack {
                    Text(stopName(change.stopID)).font(.subheadline).lineLimit(1)
                    Spacer()
                    Text("\(change.from) → \(change.to)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.brand)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stopName(change.stopID)) moves from position \(change.from) to \(change.to)")
            }
        }


    }

    private func stopName(_ id: StopID) -> String {
        guard let s = snapshot.stops.first(where: { $0.id == id }) else { return "Removed stop" }
        return [s.address.streetLine, s.address.unitLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
