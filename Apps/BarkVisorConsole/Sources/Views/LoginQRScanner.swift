#if os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    struct LoginQRScanner: View {
        var onCode: (String) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            QRScannerRepresentable { value in
                onCode(value)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan sign-in QR")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct QRScannerRepresentable: UIViewControllerRepresentable {
        var onCode: (String) -> Void

        func makeUIViewController(context: Context) -> ScannerViewController {
            let controller = ScannerViewController()
            controller.onCode = onCode
            return controller
        }

        func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
            uiViewController.onCode = onCode
        }
    }

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return }
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]
            }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer.addSublayer(preview)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.startRunning()
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
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
