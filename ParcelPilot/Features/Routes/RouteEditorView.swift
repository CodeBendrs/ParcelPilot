import ParcelPilotKit
import SwiftUI

/// Create a route or edit its settings. Settings that affect planning bump the route's input
/// revision (any existing optimized times become outdated).
struct RouteEditorView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    var route: Route?

    @State private var name = ""
    @State private var serviceDate = Date()
    @State private var timeZoneID = TimeZone.current.identifier.hasPrefix("America/") ? TimeZone.current.identifier : "America/Toronto"
    @State private var departureMinute = 8 * 60
    @State private var start: RoutePlace?
    @State private var end: RoutePlace?
    @State private var returnToStart = true
    @State private var hasLatestArrival = false
    @State private var latestArrivalMinute = 17 * 60
    @State private var serviceSeconds = 120
    @State private var hasBreak = false
    @State private var breakEarliest = 11 * 60 + 30
    @State private var breakLatest = 13 * 60 + 30
    @State private var breakMinutes = 30
    @State private var objective = OptimizationObjective.balanced
    @State private var considerTraffic = true
    @State private var picking: PlaceTarget?
    @State private var locating = false
    @State private var error: String?
    @State private var createdRoute: Route?

    enum PlaceTarget: String, Identifiable { case start, end; var id: String { rawValue } }

    private var tz: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    private var arrivalError: String? {
        guard hasLatestArrival else { return nil }
        if latestArrivalMinute >= 2880 { return "Choose an arrival time on the route date or the next day." }
        if latestArrivalMinute <= departureMinute { return "Latest arrival must be after departure. Choose Next day for an overnight route." }
        if (returnToStart ? start : end) == nil { return "Set your warehouse as Start and return to it, or choose an End location." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    TextField("Name", text: $name).accessibilityIdentifier("routeName")
                    DatePicker("Date", selection: $serviceDate, displayedComponents: .date)
                        .environment(\.timeZone, tz)
                    Picker("Time zone", selection: $timeZoneID) {
                        ForEach(WallClock.canadianTimeZones, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    MinutePicker(title: "Departure", minute: $departureMinute, timeZone: tz)
                }

                Section {
                    PlaceRow(title: "Start", place: start, empty: "Not set — needed to plan the route") { picking = .start } clear: { start = nil }
                        .accessibilityIdentifier("routeStart")
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        Label(locating ? "Finding your location…" : "Use my current location as start", systemImage: "location")
                    }
                    .disabled(locating)
                    Toggle("Return to start", isOn: $returnToStart)
                    if !returnToStart {
                        PlaceRow(title: "End", place: end, empty: "Ends at the last stop") { picking = .end } clear: { end = nil }
                            .accessibilityIdentifier("routeEnd")
                    }
                    Toggle("Latest arrival time", isOn: $hasLatestArrival)
                        .accessibilityIdentifier("latestArrivalToggle")
                    if hasLatestArrival {
                        MinutePicker(title: returnToStart ? "Back by" : "Arrive by", minute: $latestArrivalMinute, timeZone: tz, allowNextDay: true)
                            .accessibilityIdentifier("latestArrivalTime")
                    }
                } header: {
                    Text("Start and end")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasLatestArrival {
                            Text(returnToStart ? "Set Start to your warehouse. The plan must get you back by this time, including the drive after your last delivery." : "Set End to your warehouse. The plan must arrive by this time, including the drive after your last delivery.")
                            if let arrivalError { Text(arrivalError).foregroundStyle(Theme.danger) }
                        } else {
                            Text("Your location is only used when you tap the button. You can always search for an address instead.")
                        }
                    }
                }

                Section {
                    Stepper("Time at each stop: \(DisplayFormat.serviceDuration(seconds: serviceSeconds))", value: $serviceSeconds, in: 0...1800, step: 30)
                    Toggle("Required break", isOn: $hasBreak.animation())
                    if hasBreak {
                        MinutePicker(title: "Break can start from", minute: $breakEarliest, timeZone: tz)
                        MinutePicker(title: "Break must start by", minute: $breakLatest, timeZone: tz)
                        Stepper("Break length: \(breakMinutes) min", value: $breakMinutes, in: 5...120, step: 5)
                    }
                } header: {
                    Text("Stops and breaks")
                } footer: {
                    if hasBreak && breakLatest < breakEarliest { Text("The latest start must be after the earliest start.").foregroundStyle(Theme.danger) }
                }

                Section {
                    Picker("Optimize for", selection: $objective) {
                        ForEach(OptimizationObjective.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Use traffic-aware estimates", isOn: $considerTraffic)
                } header: {
                    Text("Planning")
                } footer: {
                    Text("Traffic-aware estimates use expected traffic for your departure time. They are estimates, not live traffic.")
                }

                if let error { Section { Banner(symbol: "exclamationmark.triangle", text: error, tone: .danger) } }
            }
            .navigationTitle(route == nil ? "New route" : "Route settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(route == nil ? "Create" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || arrivalError != nil || (hasBreak && breakLatest < breakEarliest))
                        .accessibilityIdentifier("saveRoute")
                }
            }
            .sheet(item: $picking) { target in
                PlaceSearchView(title: target == .start ? "Start location" : "End location") { place in
                    if target == .start { start = place } else { end = place }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let route else {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            name = "Route \(f.string(from: Date()))"
            serviceSeconds = services.settings.settings.defaultServiceSeconds
            return
        }
        name = route.name
        timeZoneID = route.timeZoneID
        if let d = WallClock.ServiceDate(iso: route.serviceDate) {
            serviceDate = WallClock.instant(serviceDate: d, minute: 12 * 60, timeZone: route.timeZone).date
        }
        departureMinute = route.departureMinute
        start = route.start
        end = route.end
        returnToStart = route.returnToStart
        hasLatestArrival = route.latestArrivalMinute != nil
        latestArrivalMinute = route.latestArrivalMinute ?? min(2879, max(17 * 60, departureMinute + 60))
        serviceSeconds = route.defaultServiceSeconds
        if let b = route.breakRule {
            hasBreak = true
            breakEarliest = b.earliestStartMinute
            breakLatest = b.latestStartMinute
            breakMinutes = b.durationSeconds / 60
        }
        objective = route.objective
        considerTraffic = route.considerTraffic
    }

    private func save() {
        let date = WallClock.ServiceDate.today(in: tz, now: serviceDate).iso
        let breakRule = hasBreak ? BreakRequirement(earliestStartMinute: breakEarliest, latestStartMinute: breakLatest, durationSeconds: breakMinutes * 60) : nil
        if var r = route ?? createdRoute {
            r.name = String(name.prefix(80))
            r.serviceDate = date
            r.timeZoneID = timeZoneID
            r.departureMinute = departureMinute
            r.start = start
            r.end = returnToStart ? nil : end
            r.returnToStart = returnToStart
            r.latestArrivalMinute = hasLatestArrival ? latestArrivalMinute : nil
            r.defaultServiceSeconds = serviceSeconds
            r.breakRule = breakRule
            r.objective = objective
            r.considerTraffic = considerTraffic
            guard services.store.updateSettings(r).isCommitted else {
                error = services.store.persistenceIssue ?? "The route couldn't be saved on this iPhone. Try again."
                return
            }
        } else {
            var created = services.store.createRoute(name: String(name.prefix(80)), serviceDate: date, timeZoneID: timeZoneID, departureMinute: departureMinute, defaultServiceSeconds: serviceSeconds, start: start, returnToStart: returnToStart)
            guard services.store.lastCommitResult.isCommitted else {
                error = services.store.persistenceIssue ?? "The route couldn't be created on this iPhone. Try again."
                return
            }
            createdRoute = created
            if breakRule != nil || hasLatestArrival || !returnToStart || objective != .balanced || !considerTraffic {
                created.end = returnToStart ? nil : end
                created.latestArrivalMinute = hasLatestArrival ? latestArrivalMinute : nil
                created.breakRule = breakRule
                created.objective = objective
                created.considerTraffic = considerTraffic
                guard services.store.updateSettings(created).isCommitted else {
                    // Reuse the durably created route when the driver retries these settings.
                    createdRoute = created
                    error = services.store.persistenceIssue ?? "The route settings couldn't be saved. Try again."
                    return
                }
            }
        }
        dismiss()
    }

    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        do {
            let c = try await services.location.currentLocation()
            let f = DateFormatter()
            f.dateFormat = "MMM d, h:mm a"
            start = RoutePlace(label: "My location (\(f.string(from: Date())))", located: LocatedPoint(point: GeoPoint(latitude: c.latitude, longitude: c.longitude), source: .deviceLocation))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaceRow: View {
    var title: String
    var place: RoutePlace?
    var empty: String
    var choose: () -> Void
    var clear: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(place?.label ?? empty).font(.subheadline).foregroundStyle(place == nil ? Theme.warning : .secondary).lineLimit(2)
                }
                Spacer()
                if place != nil {
                    Button("Clear", role: .destructive, action: clear).buttonStyle(.borderless)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.neutral)
                }
            }
            .frame(minHeight: Theme.minTouch)
        }
        .accessibilityHint("Search for an address")
    }
}

/// Wall-clock minute picker in the route's time zone (supports next-day values for windows).
struct MinutePicker: View {
    var title: String
    @Binding var minute: Int
    var timeZone: TimeZone
    var allowNextDay = false

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    var body: some View {
        VStack(alignment: .leading) {
            DatePicker(title, selection: Binding(get: {
                calendar.date(bySettingHour: (minute % 1440) / 60, minute: minute % 60, second: 0, of: Date(timeIntervalSince1970: 1_767_268_800)) ?? Date()
            }, set: { date in
                let c = calendar.dateComponents([.hour, .minute], from: date)
                let day = minute / 1440
                minute = day * 1440 + (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .environment(\.timeZone, timeZone)
            if allowNextDay {
                Toggle("Next day (after midnight)", isOn: Binding(get: { minute >= 1440 }, set: { minute = (minute % 1440) + ($0 ? 1440 : 0) }))
                    .font(.subheadline)
            }
        }
    }
}
