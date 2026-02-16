//
//  QRScannerView.swift
//  FleetScan
//
//  Created by Florian Rousseau on 12/02/2026.
//

import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    var isActive: Bool
    var cooldownSeconds: Double = 1.0
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.cooldownSeconds = cooldownSeconds
        if isActive {
            uiViewController.start()
        } else {
            uiViewController.stop()
        }
    }

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var cooldownSeconds: Double = 1.0

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.florian.FleetScan.qr.session", qos: .userInitiated)
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didSend = false
        private var configured = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureIfNeeded()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func configureIfNeeded() {
            guard !configured else { return }
            configured = true

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) { session.addOutput(output) }
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            // Support many formats: some IoT / OEM labels are NOT QR (DataMatrix / 1D barcodes)
            let desired: [AVMetadataObject.ObjectType] = [
                .qr,
                .dataMatrix,
                .code128,
                .code39,
                .code39Mod43,
                .ean13,
                .ean8,
                .pdf417,
                .aztec,
                .itf14
            ]
            output.metadataObjectTypes = desired.filter { output.availableMetadataObjectTypes.contains($0) }

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        func start() {
            configureIfNeeded()
            guard !session.isRunning else { return }
            didSend = false
            sessionQueue.async { [weak self] in
                self?.session.startRunning()
            }
        }

        func stop() {
            guard session.isRunning else { return }
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard session.isRunning else { return }
            guard !didSend else { return }

            // Take the first readable code that has a non-empty stringValue
            for case let obj as AVMetadataMachineReadableCodeObject in metadataObjects {
                if let value = obj.stringValue, !value.isEmpty {
                    didSend = true
                    onCode?(value)
                    break
                }
            }

            guard didSend else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + cooldownSeconds) {
                self.didSend = false
            }
        }
    }
}
