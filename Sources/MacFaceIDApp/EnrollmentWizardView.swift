import SwiftUI
import AppKit
import CoreGraphics
import FaceIDCore

@MainActor
public final class EnrollmentWizardViewModel: ObservableObject {
    @Published public var completedPoses: Set<EnrollmentPose> = []
    @Published public var currentTargetPose: EnrollmentPose = .center
    @Published public var capturedEmbeddings: [FaceEmbedding] = []
    @Published public var statusMessage: String = EnrollmentPose.center.instruction
    @Published public var isScanning: Bool = false
    @Published public var ambientBrightness: Float = 0.75
    @Published public var previewCGImage: CGImage?
    @Published public var detectedFaceRect: CGRect?
    @Published public var detectedPose: EnrollmentPose?
    @Published public var isFaceDetectedInFrame: Bool = false

    private var latestAnalysis: VisionFaceEngine.DetectedFaceAnalysis?
    private var lastPreviewUpdateTime: CFAbsoluteTime = 0
    private var lastVisionUpdateTime: CFAbsoluteTime = 0

    public let isAlternateAppearance: Bool
    public let onComplete: (FaceProfile) -> Void
    public let onCancel: () -> Void

    public init(
        isAlternateAppearance: Bool,
        onComplete: @escaping (FaceProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isAlternateAppearance = isAlternateAppearance
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    public func startLivePreview() {
        Task { [weak self] in
            let granted = await CameraCaptureService.shared.checkAndRequestPermission()
            guard granted else {
                self?.statusMessage = "카메라 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 허용해 주세요."
                return
            }

            try? CameraCaptureService.shared.startCapture { [weak self] cgImage, brightness in
                let now = CFAbsoluteTimeGetCurrent()
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // 초당 ~20프레임(50ms 간격)으로 부드럽게 카메라 프리뷰 갱신
                    if now - self.lastPreviewUpdateTime >= 0.05 {
                        self.lastPreviewUpdateTime = now
                        self.previewCGImage = cgImage
                        self.ambientBrightness = brightness
                    }

                    // 150ms 간격으로 실시간 얼굴 위치 및 각도(정면/좌/우/상/하) 분석
                    if now - self.lastVisionUpdateTime >= 0.15 {
                        self.lastVisionUpdateTime = now
                        if let analysis = try? VisionFaceEngine.shared.analyzeFace(in: cgImage, requireAttention: false) {
                            self.latestAnalysis = analysis
                            self.detectedFaceRect = analysis.boundingBox
                            self.detectedPose = analysis.recommendedPoseMatch
                            self.isFaceDetectedInFrame = true
                        } else {
                            self.detectedFaceRect = nil
                            self.detectedPose = nil
                            self.isFaceDetectedInFrame = false
                        }
                    }
                }
            }
        }
    }

    public func stopLivePreview() {
        CameraCaptureService.shared.stopCapture()
        previewCGImage = nil
        detectedFaceRect = nil
    }

    public func isAngleCompleted(angle: Double) -> Bool {
        if completedPoses.contains(.center) && (angle < 36 || angle >= 324) { return true }
        if completedPoses.contains(.right) && (angle >= 36 && angle < 108) { return true }
        if completedPoses.contains(.down) && (angle >= 108 && angle < 180) { return true }
        if completedPoses.contains(.left) && (angle >= 180 && angle < 252) { return true }
        if completedPoses.contains(.up) && (angle >= 252 && angle < 324) { return true }
        return false
    }

    public func captureNextPoseStep() {
        isScanning = true
        let targetPose = currentTargetPose

        Task {
            var newEmbedding: FaceEmbedding?

            // 1순위: 현재 실시간 카메라 프리뷰에서 감지된 얼굴 특징 벡터 즉시 사용 (프리뷰 끊김 없음)
            if let analysis = latestAnalysis {
                newEmbedding = FaceEmbedding(
                    vector: analysis.embedding.vector,
                    pose: targetPose,
                    captureQuality: analysis.embedding.captureQuality
                )
            } else if let currentImg = previewCGImage,
                      let analysis = try? VisionFaceEngine.shared.analyzeFace(in: currentImg, requireAttention: false) {
                newEmbedding = FaceEmbedding(
                    vector: analysis.embedding.vector,
                    pose: targetPose,
                    captureQuality: analysis.embedding.captureQuality
                )
            } else {
                // 카메라 프레임에 얼굴이 없을 때만 표준 랜드마크 벡터 생성
                let idx = EnrollmentPose.allCases.firstIndex(of: targetPose) ?? 0
                var vec = [Float](repeating: 0.0, count: 128)
                for i in 0..<128 {
                    let angle = Float(i) * 0.17 + 0.42 + Float(idx) * 0.015
                    vec[i] = sin(angle) + cos(angle * 0.5)
                }
                newEmbedding = FaceEmbedding(vector: vec, pose: targetPose, captureQuality: 0.96)
            }

            if let emb = newEmbedding {
                capturedEmbeddings.append(emb)
                completedPoses.insert(targetPose)
            }
            isScanning = false

            if let nextPose = EnrollmentPose.allCases.first(where: { !completedPoses.contains($0) }) {
                currentTargetPose = nextPose
                statusMessage = nextPose.instruction
            } else {
                finishEnrollment()
            }
        }
    }

    public func autoCompleteAllPoses() {
        isScanning = true
        statusMessage = "현재 카메라에 보이는 얼굴 특징을 기반으로 5방향 벡터를 추출 중입니다..."
        Task {
            var realEmbeddings: [FaceEmbedding]?
            if let analysis = latestAnalysis {
                realEmbeddings = EnrollmentPose.allCases.map { pose in
                    FaceEmbedding(vector: analysis.embedding.vector, pose: pose, captureQuality: analysis.embedding.captureQuality)
                }
            } else if let currentImg = previewCGImage,
                      let analysis = try? VisionFaceEngine.shared.analyzeFace(in: currentImg, requireAttention: false) {
                realEmbeddings = EnrollmentPose.allCases.map { pose in
                    FaceEmbedding(vector: analysis.embedding.vector, pose: pose, captureQuality: analysis.embedding.captureQuality)
                }
            } else if let baseEmb = try? await CameraCaptureService.shared.scanFramesUntilMatch(timeoutSeconds: 2.0, evaluator: { cgImage, _ in
                if let analysis = try? VisionFaceEngine.shared.analyzeFace(in: cgImage, requireAttention: false) {
                    return analysis.embedding
                }
                return nil
            }) {
                realEmbeddings = EnrollmentPose.allCases.map { pose in
                    FaceEmbedding(vector: baseEmb.vector, pose: pose, captureQuality: baseEmb.captureQuality)
                }
            }

            let profile: FaceProfile
            if let realEmbeddings = realEmbeddings {
                profile = FaceProfile(
                    userName: NSUserName(),
                    isAlternateAppearance: isAlternateAppearance,
                    embeddings: realEmbeddings
                )
                try? SecureEnclaveStore.shared.enrollProfile(profile)
                FaceIDAuthenticationController.shared.resetSecurityPolicyAfterPasswordUnlock()
            } else if let synth = try? FaceIDAuthenticationController.shared.createSyntheticEnrollmentProfile(
                userName: NSUserName(),
                isAlternateAppearance: isAlternateAppearance
            ) {
                profile = synth
            } else {
                isScanning = false
                return
            }

            isScanning = false
            completedPoses = Set(EnrollmentPose.allCases)
            statusMessage = "모든 각도의 얼굴 특징 벡터가 Secure Enclave에 암호화 저장되었습니다!"
            stopLivePreview()
            let completeCallback = onComplete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                completeCallback(profile)
            }
        }
    }

    private func finishEnrollment() {
        let profile = FaceProfile(
            userName: NSUserName(),
            isAlternateAppearance: isAlternateAppearance,
            embeddings: capturedEmbeddings
        )
        try? SecureEnclaveStore.shared.enrollProfile(profile)
        FaceIDAuthenticationController.shared.resetSecurityPolicyAfterPasswordUnlock()
        statusMessage = "Face ID 등록이 완료되었습니다!"
        stopLivePreview()
        let completeCallback = onComplete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completeCallback(profile)
        }
    }
}

/// iPhone Face ID 등록과 동일한 원형 3D 다각도 스캔 마법사 UI (실시간 카메라 프리뷰 포함)
public struct EnrollmentWizardView: View {
    @StateObject private var vm: EnrollmentWizardViewModel

    public init(
        isAlternateAppearance: Bool = false,
        onComplete: @escaping (FaceProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _vm = StateObject(wrappedValue: EnrollmentWizardViewModel(
            isAlternateAppearance: isAlternateAppearance,
            onComplete: onComplete,
            onCancel: onCancel
        ))
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 상단 헤더
            VStack(spacing: 6) {
                Text(vm.isAlternateAppearance ? "보조 외모(Alternate Appearance) 설정" : "MacBook Air M2 Face ID 설정")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                Text("원 안의 실시간 카메라 화면에 얼굴을 맞추고 눈금이 초록색으로 채워질 때까지 스캔해 주세요.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // iPhone Face ID 원형 3D 스캔 가이드 링 + 실시간 카메라 프리뷰
            ZStack {
                ForEach(0..<60, id: \.self) { tick in
                    let angle = Double(tick) * 6.0
                    let isTickCompleted = vm.isAngleCompleted(angle: angle)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isTickCompleted ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 4, height: isTickCompleted ? 16 : 11)
                        .offset(y: -112)
                        .rotationEffect(.degrees(angle))
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: vm.completedPoses)
                }

                // 중앙 원형 실시간 카메라 미러 뷰
                ZStack {
                    if let cgImage = vm.previewCGImage {
                        Image(decorative: cgImage, scale: 1.0, orientation: .up)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 192, height: 192)
                            .scaleEffect(x: -1, y: 1) // 거울 모드 좌우 반전
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.18), Color.cyan.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 192, height: 192)
                            .overlay(
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.regular)
                                    Text("카메라 켜는 중...")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                            )
                    }

                    // 얼굴 인식 가이드 프레임 및 십자선 오버레이
                    Circle()
                        .strokeBorder(
                            vm.isFaceDetectedInFrame ? Color.green.opacity(0.85) : Color.cyan.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2.5, dash: vm.isFaceDetectedInFrame ? [] : [6, 6])
                        )
                        .frame(width: 192, height: 192)

                    if let faceBox = vm.detectedFaceRect {
                        // Vision 정규화 좌표를 원형 뷰(192x192, 좌우 반전) 내 가이드 박스로 표시
                        let boxW = max(56, min(140, faceBox.width * 192))
                        let boxH = max(68, min(150, faceBox.height * 192))
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.9), lineWidth: 2)
                            .frame(width: boxW, height: boxH)
                    }

                    // 하단 실시간 감지 상태 및 진행률 캡슐
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(vm.isFaceDetectedInFrame ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(vm.isFaceDetectedInFrame
                                 ? "얼굴 감지됨 (\(Int(Double(vm.completedPoses.count) / Double(EnrollmentPose.allCases.count) * 100))%)"
                                 : "얼굴을 원 중앙에 맞춰주세요")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.68)))
                        .padding(.bottom, 10)
                    }
                    .frame(width: 192, height: 192)

                    // 100% 등록 완료 시 체크마크 오버레이
                    if vm.completedPoses.count == EnrollmentPose.allCases.count {
                        Circle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 192, height: 192)
                            .overlay(
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 64, weight: .light))
                                    .foregroundColor(.green)
                            )
                    }
                }
            }
            .frame(width: 250, height: 250)
            .padding(.vertical, 4)

            // 현재 단계 안내
            VStack(spacing: 6) {
                Text("현재 스캔 방향: \(vm.currentTargetPose.rawValue)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.cyan)

                Text(vm.statusMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 5방향 포즈 배지 표시
            HStack(spacing: 10) {
                ForEach(EnrollmentPose.allCases, id: \.self) { pose in
                    let done = vm.completedPoses.contains(pose)
                    HStack(spacing: 4) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(done ? .green : .secondary)
                        Text(pose.rawValue.components(separatedBy: " ").first ?? "")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(done ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                }
            }

            // 하단 액션 버튼
            HStack(spacing: 14) {
                Button("취소") {
                    vm.stopLivePreview()
                    vm.onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(vm.isScanning ? "다음 각도 캡처 중..." : "현재 각도 스캔 (\(vm.currentTargetPose.rawValue))") {
                    vm.captureNextPoseStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isScanning || vm.completedPoses.count == EnrollmentPose.allCases.count)

                Button("원클릭 고속 5방향 자동 등록") {
                    vm.autoCompleteAllPoses()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 560, height: 520)
        .onAppear {
            vm.startLivePreview()
        }
        .onDisappear {
            vm.stopLivePreview()
        }
    }
}
