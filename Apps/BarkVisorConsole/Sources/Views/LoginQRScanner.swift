#if os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    struct LoginQRScanner: View {
        var onCode: (String) -> Void
        var onFailure: (String) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            QRScannerRepresentable(
                onCode: { value in
                    onCode(value)
                    dismiss()
                },
                onFailure: { message in
                    onFailure(message)
                    dismiss()
                },
            )
            .ignoresSafeArea()
            .navigationTitle("Scan sign-in QR")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct QRScannerRepresentable: UIViewControllerRepresentable {
        var onCode: (String) -> Void
        var onFailure: (String) -> Void

        func makeUIViewController(context: Context) -> ScannerViewController {
            let controller = ScannerViewController()
            controller.onCode = onCode
            controller.onFailure = onFailure
            return controller
        }

        func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
            uiViewController.onCode = onCode
            uiViewController.onFailure = onFailure
        }
    }

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onFailure: ((String) -> Void)?
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "dev.barkvisor.login-qr")
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var handled = false
        private var appeared = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.finishAuthorization(granted: granted)
                    }
                }
            default:
                fail(.cameraDenied)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            startIfNeeded()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            appeared = false
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        private func finishAuthorization(granted: Bool) {
            if let failure = LoginQRScanError.failure(authorized: granted, cameraPresent: true) {
                fail(failure)
                return
            }
            configureSession()
            startIfNeeded()
        }

        private func configureSession() {
            let device = AVCaptureDevice.default(for: .video)
            if let failure = LoginQRScanError.failure(authorized: true, cameraPresent: device != nil) {
                fail(failure)
                return
            }
            guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
            else {
                fail(.cameraUnavailable)
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]
            }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func startIfNeeded() {
            guard appeared, !handled, !session.inputs.isEmpty else { return }
            sessionQueue.async { [weak self] in
                guard let self, self.appeared, !self.handled else { return }
                if !self.session.isRunning { self.session.startRunning() }
                if !self.appeared, self.session.isRunning { self.session.stopRunning() }
            }
        }

        private func fail(_ error: LoginQRScanError) {
            guard !handled else { return }
            handled = true
            onFailure?(error.rawValue)
        }

        func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from _: AVCaptureConnection,
        ) {
            guard !handled,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue
            else { return }
            handled = true
            session.stopRunning()
            onCode?(value)
        }
    }
#else
    enum LoginQRScannerUnavailable {}
#endif
