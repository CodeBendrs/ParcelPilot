import AVFoundation
import ParcelPilotKit
import SwiftUI
import VisionKit

/// Bridge for controlling the live scanner from SwiftUI (shutter, torch).
@MainActor
@Observable
final class ScannerController {
    fileprivate weak var scanner: DataScannerViewController?
    private(set) var labelInView = false
    private(set) var torchOn = false
    var autoCaptureEnabled = false
    var onCapture: ((UIImage) -> Void)?
    private var stableSince: Date?
    private var capturing = false

    var isRunning: Bool { scanner?.isScanning ?? false }

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return DataScannerViewController.isSupported
        #endif
    }
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return DataScannerViewController.isAvailable
        #endif
    }

    func capture() {
        guard let scanner, !capturing else { return }
        capturing = true
        Task {
            defer { capturing = false }
            if let image = try? await scanner.capturePhoto() { onCapture?(image) }
        }
    }

    func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            torchOn = on
        } catch {
            torchOn = false
        }
    }

    var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    func stop() {
        if torchOn { setTorch(false) }
        scanner?.stopScanning()
    }

    func start() {
        try? scanner?.startScanning()
    }

    /// Live text gives a cheap signal that an address label is in frame: a recipient heading or a
    /// postal-code-shaped token. Batch mode captures once the signal is stable for a moment.
    fileprivate func update(items: [RecognizedItem]) {
        let texts = items.compactMap { item -> String? in
            if case let .text(t) = item { return t.transcript }
            return nil
        }
        let joined = OCRText.normalizeConfusableScripts(texts.joined(separator: "\n"))
        let hasPostal = PostalCodeScanner.read(in: joined)?.validCode != nil
        let hasHeading = texts.contains { LabelAnalyzer.heading(in: $0)?.role == .recipient }
        labelInView = hasPostal || hasHeading
        if labelInView && hasPostal {
            if stableSince == nil { stableSince = Date() }
            if autoCaptureEnabled, let since = stableSince, Date().timeIntervalSince(since) > 0.8 {
                stableSince = nil
                capture()
            }
        } else {
            stableSince = nil
        }
    }
}

/// VisionKit live scanner (text + barcodes) with highlighting, guidance and pinch-to-zoom.
struct LiveScannerView: UIViewControllerRepresentable {
    var controller: ScannerController

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let supported = DataScannerViewController.supportedTextRecognitionLanguages
        let languages = ["en-US", "fr-FR", "en-CA", "fr-CA"].filter { supported.contains($0) }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(languages: languages.isEmpty ? [] : languages), .barcode()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        controller.scanner = scanner
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        controller.scanner = scanner
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        // Release the camera as soon as the scanner leaves the screen.
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let controller: ScannerController
        init(controller: ScannerController) { self.controller = controller }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            MainActor.assumeIsolated { controller.update(items: allItems) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            MainActor.assumeIsolated { controller.update(items: allItems) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            MainActor.assumeIsolated { controller.update(items: allItems) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            AppLog.scan.error("Scanner unavailable: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Still-photo camera fallback (devices without live scanning support).
struct CameraCaptureView: UIViewControllerRepresentable {
    var onImage: (UIImage?) -> Void

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
    }
}
