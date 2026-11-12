import AVFoundation
import SwiftUI
import UIKit
import VisionKit

struct ServerQRCodeButton: View {
    let onScan: (String) -> Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingScanner = false
    @State private var requestingAccess = false
    @State private var feedback: Feedback?

    private enum Feedback {
        case cameraAccess, unavailable
    }

    var body: some View {
        Group {
            if DataScannerViewController.isSupported {
                Button(action: scan) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                .disabled(requestingAccess)
                .accessibilityIdentifier("wherewolf.scanQRCode")

                if let feedback {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(feedback == .cameraAccess
                             ? "Allow camera access to scan a QR code."
                             : "QR scanning is unavailable right now.")
                            .foregroundStyle(.secondary)
                        if feedback == .cameraAccess {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            ServerQRCodeSheet(onScan: onScan)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, feedback == .cameraAccess,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                feedback = nil
            }
        }
    }

    private func scan() {
        feedback = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScanner()
        case .notDetermined:
            requestingAccess = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    requestingAccess = false
                    if granted { presentScanner() } else { feedback = .cameraAccess }
                }
            }
        case .denied, .restricted:
            feedback = .cameraAccess
        @unknown default:
            feedback = .unavailable
        }
    }

    private func presentScanner() {
        guard DataScannerViewController.isAvailable else {
            feedback = .unavailable
            return
        }
        showingScanner = true
    }
}

private struct ServerQRCodeSheet: View {
    let onScan: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedback: Feedback?

    private enum Feedback {
        case invalidCode, unavailable

        var message: String {
            switch self {
            case .invalidCode: "This QR code isn't a server setup code."
            case .unavailable: "QR scanning is unavailable right now."
            }
        }
    }

    var body: some View {
        NavigationStack {
            QRScannerCamera(isActive: scenePhase == .active, onScan: onScan,
                            onAccepted: { dismiss() },
                            onRejected: { showFeedback(.invalidCode) },
                            onUnavailable: { showFeedback(.unavailable) })
                .accessibilityLabel("QR code camera")
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        Text("Point the camera at a server setup QR code.")
                        if let feedback {
                            Text(feedback.message)
                                .accessibilityIdentifier("wherewolf.scanQRCode.message")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
                .navigationTitle("Scan QR Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    private func showFeedback(_ value: Feedback) {
        guard feedback != value else { return }
        feedback = value
        UIAccessibility.post(notification: .announcement, argument: value.message)
    }
}

private struct QRScannerCamera: UIViewControllerRepresentable {
    let isActive: Bool
    let onScan: (String) -> Bool
    let onAccepted: () -> Void
    let onRejected: () -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onScan = onScan
        controller.onAccepted = onAccepted
        controller.onRejected = onRejected
        controller.onUnavailable = onUnavailable
        controller.setActive(isActive)
    }

    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) {
        controller.setActive(false)
    }
}

private final class QRScannerController: UIViewController, DataScannerViewControllerDelegate {
    var onScan: (String) -> Bool = { _ in false }
    var onAccepted: () -> Void = {}
    var onRejected: () -> Void = {}
    var onUnavailable: () -> Void = {}

    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: true,
        isHighlightingEnabled: true
    )
    private var active = false
    private var visible = false
    private var accepted = false
    private var failed = false
    private var attemptedItems = Set<UUID>()

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        updateScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }

    func setActive(_ active: Bool) {
        self.active = active
        updateScanning()
    }

    private func updateScanning() {
        guard active, visible, !accepted, !failed else {
            scanner.stopScanning()
            return
        }
        guard DataScannerViewController.isAvailable else {
            scanningUnavailable()
            return
        }
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            scanningUnavailable()
        }
    }

    private func scanningUnavailable() {
        guard !failed, !accepted else { return }
        failed = true
        scanner.stopScanning()
        Task { @MainActor [weak self] in self?.onUnavailable() }
    }

    private func recognize(_ item: RecognizedItem) {
        guard active, visible, !accepted, !failed,
              case .barcode(let barcode) = item,
              let value = barcode.payloadStringValue,
              attemptedItems.insert(item.id).inserted else { return }
        if onScan(value) {
            accepted = true
            scanner.stopScanning()
            onAccepted()
        } else {
            onRejected()
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        addedItems.forEach(recognize)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        updatedItems.forEach(recognize)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        for item in removedItems { attemptedItems.remove(item.id) }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        attemptedItems.remove(item.id)
        recognize(item)
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        scanningUnavailable()
    }
}
