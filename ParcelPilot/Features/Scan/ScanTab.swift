import AVFoundation
import ParcelPilotKit
import PhotosUI
import SwiftUI

struct ScanTab: View {
    var selectTab: (AppTab) -> Void
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        NavigationStack {
            if let snapshot = services.store.current {
                ScanScreen(snapshot: snapshot, selectTab: selectTab)
            } else {
                StateMessageView(symbol: "barcode.viewfinder", title: "Choose a route to scan into", message: "Scanned packages are added to the open route.", actions: [
                    .init(title: "Go to routes", symbol: "map") { selectTab(.route) },
                ])
                .navigationTitle("Scan")
            }
        }
    }
}

struct ScanScreen: View {
    let snapshot: RouteSnapshot
    var selectTab: (AppTab) -> Void

    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScanModel?
    @State private var controller = ScannerController()
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoItem: PhotosPickerItem?
    @State private var showStillCamera = false
    @State private var showReview = false
    @State private var showManual = false
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                cameraArea
                if let model { overlay(model) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .padding(.horizontal, Theme.Space.s)
            controls
        }
        .background(Theme.background)
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showReview = true } label: {
                    let n = services.drafts.drafts(for: snapshot.route.id).count
                    Label(n > 0 ? "Review (\(n))" : "Review", systemImage: n > 0 ? "tray.full.fill" : "tray")
                }
                .accessibilityIdentifier("reviewQueue")
            }
        }
        .onAppear {
            if model == nil { model = ScanModel(services: services, toasts: toasts) }
            visible = true
            controller.onCapture = { image in handle(image, automatic: model?.batchMode ?? false) }
            Task.detached(priority: .utility) { _ = VisionLabelReader.warmUpOnce }
        }
        .onDisappear {
            visible = false
            controller.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.stop() } else if visible {
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                controller.start()
            }
        }
        .onChange(of: model?.batchMode) { _, batch in controller.autoCaptureEnabled = batch ?? false }
        .onChange(of: model?.confirmation == nil) { _, closed in
            controller.autoCaptureEnabled = closed && (model?.batchMode ?? false)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { handle(image, automatic: false) }
                photoItem = nil
            }
        }
        .sheet(item: Binding(get: { model?.confirmation }, set: { model?.confirmation = $0 })) { box in
            AddressConfirmationView(candidate: box.candidate) { outcome in model?.confirmationFinished(outcome) }
        }
        .sheet(isPresented: $showReview) { ReviewQueueView(routeID: snapshot.route.id) }
        .sheet(isPresented: $showManual) { ManualAddView(routeID: snapshot.route.id) }
        .fullScreenCover(isPresented: $showStillCamera) {
            CameraCaptureView { image in
                showStillCamera = false
                if let image { handle(image, automatic: false) }
            }
            .ignoresSafeArea()
        }
    }

    private func handle(_ image: UIImage, automatic: Bool) {
        guard let cg = image.cgImage, let model else { return }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        Task { await model.process(image: cg, orientation: orientation, automatic: automatic) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Side by side when it fits; stacked at large text sizes so "Batch" never wraps mid-word.
            ViewThatFits(in: .horizontal) {
                HStack {
                    routeName
                    Spacer()
                    batchToggle
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    routeName
                    batchToggle
                }
            }
            if model?.batchMode == true {
                Text("Batch mode: clear, verified labels are added automatically with Undo. Anything uncertain goes to review — keep scanning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private var routeName: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Adding to").font(.caption).foregroundStyle(.secondary)
            Text(snapshot.route.name).font(.headline).lineLimit(2)
        }
    }

    @ViewBuilder private var batchToggle: some View {
        if let model {
            Toggle(isOn: Binding(get: { model.batchMode }, set: { model.batchMode = $0 })) {
                Label("Batch", systemImage: "square.stack.3d.down.forward").lineLimit(1)
            }
            .toggleStyle(.button)
            .tint(Theme.teal)
            .fixedSize()
            .frame(minHeight: Theme.minTouch)
            .accessibilityIdentifier("batchToggle")
            .accessibilityHint("Adds clear, verified labels automatically and sends uncertain ones to review")
        }
    }

    // MARK: Camera / fallbacks

    @ViewBuilder private var cameraArea: some View {
        if !ScannerController.isSupported && !CameraCaptureView.isAvailable {
            fallback(title: "No camera available", message: "Import a photo of a label or type the address to add a stop.", showSettings: false)
        } else {
            switch cameraStatus {
            case .notDetermined:
                permissionPrompt
            case .denied:
                fallback(title: "Camera access is off", message: "Turn on camera access in Settings to scan labels, or import a photo of the label / type the address.", showSettings: true)
            case .restricted:
                fallback(title: "Camera is restricted", message: "This iPhone doesn't allow camera use. Import a photo of the label or type the address.", showSettings: false)
            default:
                if ScannerController.isSupported && ScannerController.isAvailable {
                    LiveScannerView(controller: controller)
                        .accessibilityLabel("Camera viewfinder")
                } else if CameraCaptureView.isAvailable {
                    fallback(title: "Live scanning isn't available on this iPhone", message: "Take a photo of the label instead — it's read the same way, on this iPhone.", showSettings: false, showCamera: true)
                } else {
                    fallback(title: "No camera available", message: "This device (for example the Simulator) has no camera. Import a photo of a label or type the address.", showSettings: false)
                }
            }
        }
    }

    private var permissionPrompt: some View {
        FitOrScroll {
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "camera.viewfinder").font(.system(size: 48)).foregroundStyle(.white)
                Text("Scan labels with the camera").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("The camera reads the SHIP TO address on this iPhone. Label photos are not saved or uploaded.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                Button("Allow camera") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .accessibilityIdentifier("allowCamera")
            }
            .padding(Theme.Space.xl)
        }
    }

    private func fallback(title: String, message: String, showSettings: Bool, showCamera: Bool = false) -> some View {
        FitOrScroll {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "camera.metering.unknown").font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                Text(title).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                if showCamera {
                    Button { showStillCamera = true } label: { Label("Take photo of label", systemImage: "camera") }
                        .buttonStyle(PrimaryActionButtonStyle())
                }
                if showSettings {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        .buttonStyle(PrimaryActionButtonStyle(filled: false))
                }
            }
            .padding(Theme.Space.xl)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Overlay

    private func overlay(_ model: ScanModel) -> some View {
        ZStack {
            if cameraStatus == .authorized, ScannerController.isSupported {
                RoundedRectangle(cornerRadius: Theme.Radius.l)
                    .strokeBorder(controller.labelInView ? Theme.success : .white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: controller.labelInView ? [] : [10, 6]))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 60)
                    .accessibilityHidden(true)
                VStack {
                    Text(controller.labelInView ? "Address in view" : "Fit the SHIP TO / DESTINATAIRE address inside the frame")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 18)
                    Spacer()
                }
            }
            VStack {
                Spacer()
                if model.phase != .idle {
                    HStack { ProgressView().tint(.white); Text(model.statusMessage ?? "").foregroundStyle(.white).font(.subheadline.weight(.semibold)) }
                        .padding(10).background(.black.opacity(0.6), in: Capsule())
                } else if let message = model.statusMessage {
                    Banner(symbol: "exclamationmark.triangle.fill", text: message, tone: .warning, actionTitle: "OK") { model.clearStatus() }
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                }
                ForEach(model.hints, id: \.self) { hint in
                    Text(hint).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(8).background(Theme.warning.opacity(0.85), in: Capsule())
                }
            }
            .padding(Theme.Space.m)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Theme.Space.l) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Import", systemImage: "photo.on.rectangle").labelStyle(.verticalCompact)
            }
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            .accessibilityLabel("Import a photo of a label")
            .accessibilityIdentifier("importPhoto")

            if controller.hasTorch && cameraStatus == .authorized {
                Button { controller.setTorch(!controller.torchOn) } label: {
                    Label(controller.torchOn ? "Light on" : "Light", systemImage: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").labelStyle(.verticalCompact)
                }
                .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            }

            Spacer()
            Button {
                if ScannerController.isSupported && cameraStatus == .authorized { controller.capture() } else if CameraCaptureView.isAvailable && cameraStatus == .authorized { showStillCamera = true }
            } label: {
                ZStack {
                    Circle().fill(Theme.brand).frame(width: 72, height: 72)
                    Image(systemName: "viewfinder").font(.title.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .disabled(!canCapture)
            .opacity(canCapture ? 1 : 0.35)
            .accessibilityLabel("Capture label")
            .accessibilityIdentifier("shutter")
            Spacer()

            Button { showManual = true } label: {
                Label("Type", systemImage: "keyboard").labelStyle(.verticalCompact)
            }
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
            .accessibilityLabel("Type the address instead")
            .accessibilityIdentifier("typeAddress")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private var canCapture: Bool {
        !(model?.isBusy ?? true) && cameraStatus == .authorized && (ScannerController.isAvailable || CameraCaptureView.isAvailable)
    }
}

struct VerticalCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title
        }
    }
}

extension LabelStyle where Self == VerticalCompactLabelStyle {
    static var verticalCompact: VerticalCompactLabelStyle { VerticalCompactLabelStyle() }
}

/// Scanned labels waiting for a decision. Nothing here is on the route until confirmed.
struct ReviewQueueView: View {
    let routeID: RouteID
    @Environment(AppServices.self) private var services
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CandidateBox?
    @State private var verifying = false

    var body: some View {
        NavigationStack {
            let drafts = services.drafts.drafts(for: routeID)
            List {
                if drafts.isEmpty {
                    StateMessageView(symbol: "tray", title: "Nothing to review", message: "Uncertain or offline scans appear here. They are never added to the route without your confirmation.", tone: .success)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    if drafts.contains(where: { $0.state == .needsVerification }) {
                        Section {
                            Button {
                                Task { await verifyAll(drafts) }
                            } label: {
                                Label(verifying ? "Checking…" : "Check offline scans now", systemImage: "checkmark.magnifyingglass")
                            }
                            .disabled(verifying || !services.connectivity.isOnline)
                        } footer: {
                            if !services.connectivity.isOnline { Text("You're offline. These will be checked when you reconnect.") }
                        }
                    }
                    Section("\(drafts.count) to review") {
                        ForEach(drafts) { draft in
                            Button { editing = CandidateBox(candidate: .fromDraft(draft)) } label: { DraftRow(draft: draft) }
                                .buttonStyle(.row)
                                .swipeActions { Button("Discard", role: .destructive) { services.drafts.remove(draft.id) } }
                        }
                    }
                }
            }
            .navigationTitle("Review queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { box in
                AddressConfirmationView(candidate: box.candidate) { outcome in
                    if case let .added(m) = outcome { toasts.show(m, symbol: "checkmark.circle.fill", tone: .success) }
                }
            }
        }
    }

    private func verifyAll(_ drafts: [ScanDraft]) async {
        verifying = true
        defer { verifying = false }
        for draft in drafts where draft.state == .needsVerification {
            var candidate = IntakeCandidate.fromDraft(draft)
            candidate.verification = await services.verifier.verify(candidate.address)
            guard candidate.verification?.assessment != nil else { continue }
            services.drafts.upsert(candidate.asDraft(id: draft.id, now: draft.createdAt, allowSynthetic: services.verifier.allowsSynthetic))
        }
    }
}

struct DraftRow: View {
    var draft: ScanDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch draft.state {
            case .needsVerification: StatusBadge(text: "Needs address verification", symbol: "icloud.slash", tone: .warning, compact: true)
            case .needsReview: StatusBadge(text: "Needs review", symbol: "exclamationmark.triangle", tone: .warning, compact: true)
            case .needsChoice: StatusBadge(text: "Choose the address", symbol: "arrow.triangle.branch", tone: .warning, compact: true)
            }
            Text((draft.selected ?? draft.candidates.first)?.address.singleLine ?? "Unreadable label").font(.body.weight(.semibold)).foregroundStyle(.primary)
            if let reason = draft.reasons.first { Text(reason.explanation).font(.caption).foregroundStyle(.secondary) }
            if let t = draft.trackingIDs.first { Text("Tracking …\(t.suffix(6))").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
        .frame(minHeight: Theme.minTouch)
    }
}
