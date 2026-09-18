// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVFoundation
import RemoteCore

final class QRScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var message = "正在准备摄像头…"
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.wifiremote.qr-camera")
    private var wanted = false
    private var lastFrame = Date.distantPast
    private var delivered = false
    private let onScan: (PairingOffer) -> Void

    init(onScan: @escaping (PairingOffer) -> Void) { self.onScan = onScan }
    private func report(_ text: String) { DispatchQueue.main.async { self.message = text } }
    func start() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.delivered = false
            self.lastFrame = .distantPast
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.queue.async {
                        guard self.wanted else { return }
                        if granted { self.configure() } else { self.report("未允许摄像头访问。可在系统设置中允许，或使用手动配对。") }
                    }
                }
            default: self.report("无法访问摄像头。请在系统设置 → 隐私与安全性 → 摄像头中允许此应用，或使用手动配对。")
            }
        }
    }
    private func configure() {
        guard wanted, session.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else { report("未找到摄像头，请连接摄像头或使用手动配对。"); return }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration(); report("摄像头暂不可用，请关闭其他占用摄像头的应用后重试。"); return
            }
            session.addInput(input); session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            report(session.isRunning ? "将手机的配对二维码放入画面，识别后自动连接。" : "摄像头启动失败，请重试或使用手动配对。")
        } catch { report("摄像头启动失败，请重试或使用手动配对。") }
    }
    func stop() {
        queue.async {
            self.wanted = false
            self.session.stopRunning()
            for output in self.session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                self.session.removeOutput(output)
            }
            for input in self.session.inputs { self.session.removeInput(input) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wanted, !delivered, Date().timeIntervalSince(lastFrame) > 0.25,
              let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()
        guard let offer = try? PairingQR.decode(frame: frame) else { return }
        delivered = true
        stop()
        DispatchQueue.main.async { self.onScan(offer) }
    }
}

private final class CameraView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView { CameraView(session: session) }
    func updateNSView(_ view: NSView, context: Context) { }
}

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner: QRScanner
    init(onScan: @escaping (PairingOffer) -> Void) { _scanner = StateObject(wrappedValue: QRScanner(onScan: onScan)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扫描手机二维码").font(.title2)
            Text("在手机 WiFi Remote Input 中点击「显示配对二维码」。")
            CameraPreview(session: scanner.session).frame(width: 560, height: 315).background(Color.black)
            Text(scanner.message).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("画面仅在本机识别，不保存或上传。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 608)
            .onAppear { scanner.start() }
            .onDisappear { scanner.stop() }
    }
}
