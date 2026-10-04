import ParcelPilotKit
import PhotosUI
import SwiftUI
import VisionKit

/// Find a package in the vehicle by tracking number (typed or scanned), recipient, address or
/// storage location.
struct PackageFinderView: View {
    let snapshot: RouteSnapshot
    var onSelect: (StopID) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scanning = false

    var body: some View {
        let live = services.store.current ?? snapshot
        let ledger = live.ledger
        let ordered = live.orderedStops
        let matches = results(in: live)
        NavigationStack {
            List {
                if query.isEmpty {
                    Text("Search by tracking number, last digits, recipient, street or vehicle location (e.g. “B3”).").font(.subheadline).foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    StateMessageView(symbol: "shippingbox", title: "No match", message: "This package isn't on the open route. Check the route, or add it by scanning the label.")
                }
                ForEach(matches) { p in
                    let stop = live.stops.first { $0.id == p.stopID }
                    let n = (ordered.firstIndex { $0.id == p.stopID } ?? -1) + 1
                    Button {
                        if stop != nil { onSelect(p.stopID) }
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            if n > 0 { StopNumberView(number: n, status: stop.map { ledger.stopStatus($0, packages: live.packages) } ?? .pending) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.storageLocation.map { "In vehicle: \($0)" } ?? "Vehicle location not set").font(.headline).foregroundStyle(.primary)
                                Text([stop?.address.streetLine, stop?.address.unitLabel].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.primary)
                                Text([p.trackingID, p.recipientName, ledger.status(of: p.id).label].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if stop == nil { Text("Its stop was removed — remove or re-add this package.").font(.caption).foregroundStyle(Theme.warning) }
                            }
                        }
                        .frame(minHeight: Theme.minTouch)
                    }
                    .swipeActions { if stop == nil { Button("Remove", role: .destructive) { services.store.delete(package: p, in: live) } } }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tracking, name, street, location")
            .navigationTitle("Find package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button { scanning = true } label: { Label("Scan barcode", systemImage: "barcode.viewfinder") }
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                BarcodeScannerSheet { payload in
                    query = BarcodeClassifier.normalizedTrackingID(payload) ?? payload
                    scanning = false
                }
            }
        }
    }

    private func results(in snapshot: RouteSnapshot) -> [Package] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let key = q.uppercased().filter { $0.isLetter || $0.isNumber }
        let folded = AddressText.foldForMatching(q)
        return snapshot.packages.filter { p in
            if !key.isEmpty, let t = p.trackingKey, t.contains(key) { return true }
            if let name = p.recipientName, AddressText.foldForMatching(name).contains(folded) { return true }
            if let loc = p.storageLocation, AddressText.foldForMatching(loc).contains(folded) { return true }
            if let stop = snapshot.stops.first(where: { $0.id == p.stopID }), AddressText.foldForMatching(stop.address.singleLine).contains(folded) { return true }
            return false
        }
    }
}

/// Barcode-only live scanner used by the package finder.
struct BarcodeScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BarcodeOnlyScanner(onCode: onCode)
                .ignoresSafeArea()
                .navigationTitle("Scan package barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct BarcodeOnlyScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(code) = item, let payload = code.payloadStringValue {
                    delivered = true
                    MainActor.assumeIsolated { Haptics.success(); onCode(payload) }
                    return
                }
            }
        }
    }
}

/// Optional proof-of-delivery photo. Delivery completion never depends on it.
struct PODCaptureView: View {
    let routeID: RouteID
    let stopID: StopID
    let packageIDs: [PackageID]
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "camera.on.rectangle").font(.system(size: 44)).foregroundStyle(Theme.brand)
                Text("Proof-of-delivery photo").font(.title3.weight(.semibold))
                Text(services.mode.isDemo ? "Demo mode: the photo stays on this iPhone." : "Saved on this iPhone first, then uploaded securely to your account — even if you're offline now.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if CameraCaptureView.isAvailable {
                    Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }.buttonStyle(PrimaryActionButtonStyle())
                }
                PhotosPicker(selection: $item, matching: .images) { Label("Choose from library", systemImage: "photo") }
                    .buttonStyle(PrimaryActionButtonStyle(filled: !CameraCaptureView.isAvailable))
                if let error { Banner(symbol: "exclamationmark.triangle", text: error, tone: .danger) }
            }
            .padding(Theme.Space.xl)
            .navigationTitle("Add photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } } }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { image in
                    showCamera = false
                    if let image { save(image) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: item) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { save(image) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ image: UIImage) {
        guard let jpeg = PhotoEncoder.jpeg(from: image) else { error = "The photo couldn't be processed."; return }
        do {
            _ = try services.photos.add(jpeg: jpeg, routeID: routeID, stopID: stopID, packageIDs: packageIDs)
            toasts.show(services.mode.isDemo ? "Photo saved" : "Photo saved — uploading", symbol: "photo.badge.checkmark", tone: .success)
            dismiss()
        } catch {
            self.error = "The photo couldn't be saved: \(error.localizedDescription)"
        }
    }
}

struct PhotosSection: View {
    let snapshot: RouteSnapshot
    let stop: Stop
    var add: () -> Void
    @Environment(AppServices.self) private var services
    @State private var viewing: DeliveryPhoto?

    var body: some View {
        let photos = snapshot.photos.filter { $0.stopID == stop.id }
        let pending = services.photos.pending.filter { $0.stopID == stop.id }
        Section("Proof of delivery") {
            ForEach(pending) { p in
                HStack {
                    if let image = services.photos.pendingImage(p.id) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s))
                    }
                    VStack(alignment: .leading) {
                        Text("Waiting to upload").font(.subheadline.weight(.semibold))
                        Text(p.lastError ?? "Saved on this iPhone").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { services.photos.deletePending(p.id) } }
            }
            ForEach(photos) { photo in
                Button { viewing = photo } label: {
                    Label("Photo · \(DisplayFormat.time(photo.capturedAt, timeZone: snapshot.route.timeZone))", systemImage: "photo")
                }
                .swipeActions { Button("Delete", role: .destructive) { Task { try? await services.photos.delete(photo: photo, routeID: snapshot.route.id) } } }
            }
            Button(action: add) { Label("Add photo", systemImage: "camera") }
        }
        .sheet(item: $viewing) { photo in PhotoViewer(photo: photo, routeID: snapshot.route.id) }
    }
}

struct PhotoViewer: View {
    let photo: DeliveryPhoto
    let routeID: RouteID
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if let error { Text(error).padding() }
                else { ProgressView("Loading photo…") }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { Task { try? await services.photos.delete(photo: photo, routeID: routeID); dismiss() } }
                }
            }
            .task {
                do { image = try await services.photos.image(for: photo, routeID: routeID) } catch { self.error = error.localizedDescription }
            }
        }
    }
}
