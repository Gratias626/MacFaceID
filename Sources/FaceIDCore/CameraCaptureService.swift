import Foundation
import AVFoundation
import CoreImage
import CoreGraphics

/// MacBook Air M2 내장 1080p FaceTime HD 카메라 저지연 캡처 매니저
/// 이벤트 기반 온디맨드 구동으로 대기 시 CPU 점유율 0% 및 배터리 보호를 보장합니다.
public final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let shared = CameraCaptureService()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.macfaceid.camera.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var frameHandler: ((CGImage, Float) -> Void)?
    private var isConfigured = false
    public private(set) var isRunning = false

    public override init() {
        super.init()
    }

    /// 카메라 권한 확인 및 요청
    public func checkAndRequestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// MacBook Air M2 내장 FaceTime HD 카메라 세션 구성
    public func configureSessionIfNeeded() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(
                domain: "CameraCaptureService",
                code: -201,
                userInfo: [NSLocalizedDescriptionKey: "MacBook Air 내장 FaceTime HD 카메라를 찾을 수 없습니다."]
            )
        }

        let input = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        isConfigured = true
    }

    /// 온디맨드 카메라 캡처 시작
    public func startCapture(onFrame: @escaping (CGImage, Float) -> Void) throws {
        try configureSessionIfNeeded()
        self.frameHandler = onFrame
        if !session.isRunning {
            captureQueue.async { [weak self] in
                self?.session.startRunning()
                self?.isRunning = true
            }
        }
    }

    /// 인증 완료 즉시 카메라 종료 (프라이버시 보호 및 전력 절감)
    public func stopCapture() {
        frameHandler = nil
        if session.isRunning {
            captureQueue.async { [weak self] in
                self?.session.stopRunning()
                self?.isRunning = false
            }
        }
    }

    /// 단일 프레임 스냅샷 캡처 (CLI / PAM 고속 인증용, 타임아웃 지원)
    public func captureSingleFrame(timeoutSeconds: Double = 1.5) async throws -> (CGImage, Float) {
        let hasPermission = await checkAndRequestPermission()
        guard hasPermission else {
            throw NSError(domain: "CameraCaptureService", code: -202, userInfo: [NSLocalizedDescriptionKey: "카메라 접근 권한이 거부되었습니다."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var isCompleted = false

            do {
                try startCapture { [weak self] cgImage, brightness in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !isCompleted else { return }
                    isCompleted = true
                    self?.stopCapture()
                    continuation.resume(returning: (cgImage, brightness))
                }
            } catch {
                lock.lock()
                defer { lock.unlock() }
                if !isCompleted {
                    isCompleted = true
                    continuation.resume(throwing: error)
                }
                return
            }

            captureQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                lock.lock()
                defer { lock.unlock() }
                guard !isCompleted else { return }
                isCompleted = true
                self?.stopCapture()
                continuation.resume(throwing: NSError(
                    domain: "CameraCaptureService",
                    code: -203,
                    userInfo: [NSLocalizedDescriptionKey: "카메라 프레임 캡처 타임아웃 (\(timeoutSeconds)s)"]
                ))
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let handler = frameHandler,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return }

        // 주변 조도(밝기) 추정: 저조도 환경에서 화면 보조 조명(Face Illumination) 활성화 판단용
        let brightness = estimateAmbientBrightness(from: pixelBuffer)
        handler(cgImage, brightness)
    }

    private func estimateAmbientBrightness(from pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.5 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        var totalLuma: Float = 0
        var sampleCount: Int = 0
        let step = 32

        for y in stride(from: 0, to: height, by: step) {
            let rowPtr = ptr + y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let pixel = rowPtr + x * 4
                let b = Float(pixel[0])
                let g = Float(pixel[1])
                let r = Float(pixel[2])
                let luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                totalLuma += luma
                sampleCount += 1
            }
        }

        return sampleCount > 0 ? (totalLuma / Float(sampleCount)) : 0.5
    }
}

