import ParcelPilotKit
import SwiftUI
import UniformTypeIdentifiers

struct PasteImportView: View {
    let routeID: RouteID
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var candidates: [ImportCandidate]?

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    ImportReviewView(routeID: routeID, candidates: candidates, source: .paste) { dismiss() }
                } else {
                    Form {
                        Section {
                            TextEditor(text: $text)
                                .frame(minHeight: 220)
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("pasteField")
                            Button("Paste from clipboard") { text = UIPasteboard.general.string ?? text }
                        } header: {
                            Text("Addresses")
                        } footer: {
                            Text("One address per line, or separate multi-line addresses with a blank line. Only the addresses are used — nothing is uploaded until you import.")
                        }
                        Section {
                            Button { review() } label: { Label("Review addresses", systemImage: "list.bullet.clipboard") }
                                .buttonStyle(PrimaryActionButtonStyle())
                                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("pasteReview")
                                .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .navigationTitle("Paste addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func review() {
        guard let snapshot = services.store.current else { return }
        candidates = BulkImportPlanner.fromPaste(text, index: RouteIntakeIndex(stops: snapshot.stops, packages: snapshot.packages))
    }
}

struct CSVImportView: View {
    let routeID: RouteID
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var importing = true
    @State private var rows: [[String]] = []
    @State private var hasHeader = true
    @State private var mapping: [ImportColumnRole] = []
    @State private var candidates: [ImportCandidate]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    ImportReviewView(routeID: routeID, candidates: candidates, source: .csv) { dismiss() }
                } else if rows.isEmpty {
                    StateMessageView(symbol: "tablecells", title: "Choose a CSV file", message: error ?? "Pick a .csv file from Files. Columns can be mapped on the next screen.", actions: [.init(title: "Choose file", symbol: "folder") { importing = true }], tone: error == nil ? .neutral : .danger)
                } else {
                    mappingForm
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .tabSeparatedText]) { result in
                load(result)
            }
        }
    }

    private var mappingForm: some View {
        Form {
            Section {
                Toggle("First row is a header", isOn: $hasHeader)
                LabeledContent("Rows", value: "\(rows.count - (hasHeader ? 1 : 0))")
            }
            Section {
                ForEach(mapping.indices, id: \.self) { i in
                    Picker(selection: $mapping[i]) {
                        ForEach(ImportColumnRole.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(hasHeader ? (rows.first?[safe: i] ?? "Column \(i + 1)") : "Column \(i + 1)").font(.body.weight(.semibold))
                            Text(sample(i)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Columns")
            } footer: {
                Text("Map either a full-address column, or street + city + province + postal code columns.")
            }
            Section {
                Button { review() } label: { Label("Review rows", systemImage: "list.bullet.clipboard") }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(!mapping.contains(.fullAddress) && !mapping.contains(.street))
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func sample(_ i: Int) -> String {
        let data = hasHeader ? rows.dropFirst() : rows[...]
        return data.prefix(3).compactMap { $0[safe: i] }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(e): error = e.localizedDescription
        case let .success(url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 5_000_000,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                error = "That file couldn't be read as text (max 5 MB)."
                return
            }
            let parsed = CSVReader.parse(text)
            guard parsed.count > 0 else { error = "The file has no rows."; return }
            if parsed.count > RouteLimits.maxStopsPerRoute + 1 { error = "The file has \(parsed.count) rows. Import up to \(RouteLimits.maxStopsPerRoute) per route."; return }
            rows = parsed
            let width = parsed.map(\.count).max() ?? 0
            mapping = (0..<width).map { i in ImportColumnRole.guess(header: parsed[0][safe: i] ?? "") }
            hasHeader = mapping.contains { $0 != .ignore }
        }
    }

    private func review() {
        guard let snapshot = services.store.current else { return }
        candidates = BulkImportPlanner.fromCSV(rows: rows, hasHeader: hasHeader, mapping: mapping, index: RouteIntakeIndex(stops: snapshot.stops, packages: snapshot.packages))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Per-row errors, duplicate review and batched verification before anything is written.
struct ImportReviewView: View {
    let routeID: RouteID
    @State var candidates: [ImportCandidate]
    var source: PackageSource
    var onDone: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @State private var include: Set<Int> = []
    @State private var verifying = false
    @State private var progress = 0
    @State private var results: [Int: AddressVerifier.Result] = [:]

    var body: some View {
        let importable = candidates.filter(\.isImportable)
        List {
            Section {
                LabeledContent("Ready", value: "\(importable.filter { include.contains($0.rowNumber) }.count)")
                LabeledContent("With errors (skipped)", value: "\(candidates.count - importable.count)")
                if verifying { ProgressView(value: Double(progress), total: Double(max(include.count, 1))) { Text("Checking addresses \(progress)/\(include.count)") } }
                if !services.connectivity.isOnline {
                    Banner(symbol: "icloud.slash", text: "Offline: addresses will be saved as “Needs address verification” and checked when you're back online. They won't be optimized until then.", tone: .warning)
                }
            }
            Section("Rows") {
                ForEach(candidates) { c in
                    ImportRow(candidate: c, included: include.contains(c.rowNumber), result: results[c.rowNumber]) {
                        if include.contains(c.rowNumber) { include.remove(c.rowNumber) } else if c.isImportable { include.insert(c.rowNumber) }
                    }
                }
            }
            Section {
                Button {
                    Task { await importNow() }
                } label: {
                    Label("Import \(include.count) address\(include.count == 1 ? "" : "es")", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(include.isEmpty || verifying)
                .accessibilityIdentifier("importNow")
                .listRowBackground(Color.clear)
            }
        }
        .onAppear {
            include = Set(candidates.filter { $0.isImportable && $0.duplicateOfRow == nil && $0.duplicateOfStop == nil && !$0.duplicateTracking }.map(\.rowNumber))
        }
    }

    private func importNow() async {
        guard services.store.current?.route.id == routeID else { return }
        verifying = true
        progress = 0
        defer { verifying = false }
        let chosen = candidates.filter { include.contains($0.rowNumber) }
        // Verify one at a time: gentle on server quotas, and progress stays accurate.
        for c in chosen {
            results[c.rowNumber] = await services.verifier.verify(c.parsed.address)
            progress += 1
        }
        var ops: [ChangeOp] = []
        guard var working = services.store.current else { return }
        var added = 0, review = 0
        for c in chosen {
            let result = results[c.rowNumber]
            var intake = IntakeCandidate(routeID: routeID, source: source, address: c.parsed.address, verification: result)
            intake.driverEdited = true
            let (status, resolution, reasons) = intake.confirmedStop(verifier: services.verifier, driverReviewed: false)
            let drafts = (0..<c.packageCount).map { i in PackageDraft(trackingID: i == 0 ? c.trackingID : nil, recipientName: c.parsed.address.recipientName, storageLocation: c.storageLocation, notes: c.notes ?? "") }
            let r = services.store.addDelivery(to: working, address: c.parsed.address, status: status, resolution: resolution, reviewReasons: reasons, packages: drafts, source: source, notes: c.notes ?? "", commit: false)
            ops.append(contentsOf: r.ops)
            for op in r.ops {
                switch op {
                case let .putStop(_, s): working.stops.append(s)
                case let .putPackage(_, p): working.packages.append(p)
                default: break
                }
            }
            if status == .verified || status == .demoSynthetic || status == .driverConfirmed { added += 1 } else { review += 1 }
        }
        // Collapse repeated route revision bumps into one.
        let routeOps = ops.filter { if case .updateRoute = $0 { return true }; return false }
        ops.removeAll { if case .updateRoute = $0 { return true }; return false }
        if let last = routeOps.last { ops.append(last) }
        services.store.commitPrepared(ops, label: "Import \(chosen.count) addresses")
        toasts.show("Imported \(chosen.count) address\(chosen.count == 1 ? "" : "es")" + (review > 0 ? " · \(review) need review" : ""), symbol: "square.and.arrow.down", tone: review > 0 ? .warning : .success)
        onDone()
    }
}

struct ImportRow: View {
    var candidate: ImportCandidate
    var included: Bool
    var result: AddressVerifier.Result?
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: candidate.isImportable ? (included ? "checkmark.circle.fill" : "circle") : "xmark.circle")
                    .foregroundStyle(candidate.isImportable ? Theme.brand : Theme.danger)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Row \(candidate.rowNumber)").font(.caption).foregroundStyle(.secondary)
                    Text(candidate.parsed.address.singleLine.isEmpty ? candidate.sourceText : candidate.parsed.address.singleLine).font(.subheadline).foregroundStyle(.primary)
                    ForEach(candidate.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.danger) }
                    if let d = candidate.duplicateOfRow { Text("Same destination as row \(d) — included as another package if selected.").font(.caption).foregroundStyle(Theme.warning) }
                    if candidate.duplicateOfStop != nil { Text("Already a stop on this route — adds packages to it if selected.").font(.caption).foregroundStyle(Theme.warning) }
                    if candidate.duplicateTracking { Text("Tracking number already present — it won't be added twice.").font(.caption).foregroundStyle(Theme.warning) }
                    if let a = result?.assessment { StatusBadge(text: a.quality.label, symbol: a.quality.symbol, tone: a.quality.tone, compact: true) }
                }
            }
            .frame(minHeight: Theme.minTouch)
        }
        .disabled(!candidate.isImportable)
        .accessibilityAddTraits(included ? .isSelected : [])
    }
}
