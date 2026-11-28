import AVFoundation
import SwiftUI
import VisionKit

struct PairMacView: View {
    let store: CompanionStore
    @State private var pairingCode = ""
    @State private var scanner = false

    private var isPairing: Bool {
        if case .pairing = store.connection { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Button {
                    scanner = true
                } label: {
                    Label(
                        String(localized: "pair.scan", defaultValue: "Scan Pairing Code"),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                SecureField(String(localized: "pair.code", defaultValue: "Pairing code"), text: $pairingCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { connect(pairingCode) }
                    .privacySensitive()
                Button {
                    connect(pairingCode)
                } label: {
                    if isPairing {
                        ProgressView()
                            .accessibilityLabel(String(localized: "pair.connecting", defaultValue: "Connecting"))
                    } else {
                        Text(String(localized: "pair.connect", defaultValue: "Connect"))
                    }
                }
                .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(String(localized: "pair.title", defaultValue: "Pair Your Mac"))
            } footer: {
                Text(String(localized: "pair.instructions", defaultValue: "Open Programa on your Mac to display a pairing code. Scan it or paste it here."))
            }
            .disabled(isPairing)

            if case let .unpaired(issue?) = store.connection {
                Text(issue.label).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $scanner) {
            PairingScanner { code in
                scanner = false
                connect(code)
            }
        }
    }

    private func connect(_ code: String) {
        guard !isPairing else { return }
        Task {
            if await store.pair(code, deviceName: UIDevice.current.name) {
                pairingCode = ""
            }
        }
    }
}

private struct PairingScanner: View {
    enum Camera {
        case checking, available, unavailable
    }

    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: Camera = .checking

    var body: some View {
        NavigationStack {
            Group {
                switch camera {
                case .checking:
                    ProgressView()
                case .available:
                    QRScanner(onCode: onCode, onUnavailable: { camera = .unavailable })
                        .ignoresSafeArea(edges: .bottom)
                case .unavailable:
                    ContentUnavailableView(
                        String(localized: "pair.cameraUnavailable", defaultValue: "Camera Unavailable"),
                        systemImage: "camera",
                        description: Text(
                            String(localized: "pair.pasteInstead", defaultValue: "Paste the pairing code from your Mac instead.")
                        )
                    )
                }
            }
            .navigationTitle(String(localized: "pair.scan", defaultValue: "Scan Pairing Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
            }
        }
        .task {
            guard DataScannerViewController.isSupported else {
                camera = .unavailable
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            camera = granted && DataScannerViewController.isAvailable ? .available : .unavailable
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onCode: onCode, onUnavailable: onUnavailable)
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, DataScannerViewControllerDelegate {
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighlightingEnabled: true
    )
    private let onCode: (String) -> Void
    private let onUnavailable: () -> Void

    init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
        self.onCode = onCode
        self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() } catch { onUnavailable() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        for item in addedItems {
            guard case let .barcode(barcode) = item,
                  let code = barcode.payloadStringValue,
                  MobileChatPairingCode.parse(code) != nil else { continue }
            dataScanner.stopScanning()
            onCode(code)
            return
        }
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
    ) {
        onUnavailable()
    }
}
