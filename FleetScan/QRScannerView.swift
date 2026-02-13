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
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        func start() {
            configureIfNeeded()
            guard !session.isRunning else { return }
            didSend = false
            session.startRunning()
        }

        func stop() {
            guard session.isRunning else { return }
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard session.isRunning else { return }
            guard !didSend,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue, !value.isEmpty else { return }

            didSend = true
            onCode?(value)

            DispatchQueue.main.asyncAfter(deadline: .now() + cooldownSeconds) {
                self.didSend = false
            }
        }
    }
}
