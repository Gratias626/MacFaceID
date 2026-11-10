import Foundation
import LocalAuthentication
import CoreGraphics

/// Face ID = Touch ID 통합 인증 컨트롤러
/// - 다각도 얼굴 등록 (기본 외모 + 보조 외모)
/// - 500ms 이내 초고속 인증 및 Liveness 검증
/// - iPhone Face ID 보안 정책 (연속 5회 실패 / 재부팅 후 최초 1회 / 48시간 경과 시 암호 또는 Touch ID Fallback)
public final class FaceIDAuthenticationController: @unchecked Sendable {
    public static let shared = FaceIDAuthenticationController()

    private let store: SecureEnclaveStore
    private let visionEngine: VisionFaceEngine
    private let cameraService: CameraCaptureService

    public init(
        store: SecureEnclaveStore = .shared,
        visionEngine: VisionFaceEngine = .shared,
        cameraService: CameraCaptureService = .shared
    ) {
        self.store = store
        self.visionEngine = visionEngine
        self.cameraService = cameraService
    }

    // MARK: - 1. iPhone Face ID 보안 정책 검증 (Fallback 필요 여부 확인)

    public func checkSecurityPolicyBeforeAuth() -> FallbackReason? {
        let profiles = (try? store.loadProfiles()) ?? []
        guard !profiles.isEmpty else {
            return .noEnrolledFace
        }

        let config = store.loadConfiguration()
        let state = store.loadSecurityState()

        // 1) 연속 5회(설정값) 이상 얼굴 인식 실패 시 패스워드/Touch ID 강제
        if state.consecutiveFailures >= config.maxFailureAttempts {
            return .maxConsecutiveFailures
        }

        // 2) 시스템 재부팅 직후 최초 로그인 여부 확인
        if state.lastBootTimeVerified == nil {
            return .initialLoginAfterBoot
        }

        // 3) 48시간(172,800초) 이상 Face ID 잠금 해제 이력이 없는 경우
        if let lastAuth = state.lastSuccessfulAuthDate {
            let elapsed = Date().timeIntervalSince(lastAuth)
            if elapsed > (48 * 3600) {
                return .expired48Hours
            }
        } else {
            return .initialLoginAfterBoot
        }

        return nil
    }

    // MARK: - 2. 후보 임베딩 및 Liveness 결과를 통한 오프라인/실시간 인증 판정

    public func verifyCandidate(
        candidateEmbedding: FaceEmbedding,
        liveness: LivenessResult
    ) -> AuthenticationState {
        let startTime = CFAbsoluteTimeGetCurrent()

        if let fallbackReason = checkSecurityPolicyBeforeAuth() {
            return .fallbackRequired(reason: fallbackReason)
        }

        let config = store.loadConfiguration()
        var securityState = store.loadSecurityState()

        // 1) 생체 판별(Anti-Spoofing / 시선 주시) 검증
        if !liveness.isLive {
            securityState.consecutiveFailures += 1
            store.saveSecurityState(securityState)

            if securityState.consecutiveFailures >= config.maxFailureAttempts {
                return .fallbackRequired(reason: .livenessSpoofDetected)
            }
            return .failed(
                reason: liveness.failureReason ?? "생체 인증(Liveness) 확인에 실패했습니다.",
                consecutiveFailures: securityState.consecutiveFailures
            )
        }

        // 2) 등록된 프로필(기본 외모 + 보조 외모)과 코사인 유사도 비교
        let profiles = (try? store.loadProfiles()) ?? []
        var bestMatchScore: Float = -1.0
        var matchedUser: String = NSUserName()

        for profile in profiles {
            let score = profile.matchScore(against: candidateEmbedding)
            if score > bestMatchScore {
                bestMatchScore = score
                matchedUser = profile.userName
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        // 3) 임계값(기본 0.85) 이상이면 인증 성공
        if bestMatchScore >= config.similarityThreshold {
            securityState.consecutiveFailures = 0
            securityState.lastSuccessfulAuthDate = Date()
            securityState.lastBootTimeVerified = ProcessInfo.processInfo.systemUptime
            store.saveSecurityState(securityState)

            return .authenticated(
                userName: matchedUser,
                similarity: bestMatchScore,
                elapsedMs: elapsedMs
            )
        } else {
            securityState.consecutiveFailures += 1
            store.saveSecurityState(securityState)

            if securityState.consecutiveFailures >= config.maxFailureAttempts {
                return .fallbackRequired(reason: .maxConsecutiveFailures)
            }

            return .failed(
                reason: String(format: "얼굴 일치도가 기준치 미만입니다 (유사도: %.1f%%)", max(0, bestMatchScore * 100)),
                consecutiveFailures: securityState.consecutiveFailures
            )
        }
    }

    // MARK: - 3. 실시간 카메라 연동 원스톱 Face ID 인증 (500ms 목표)

    public func authenticateWithCamera(maxFramesToTry: Int = 5) async -> AuthenticationState {
        let startTime = CFAbsoluteTimeGetCurrent()

        if let fallbackReason = checkSecurityPolicyBeforeAuth() {
            return .fallbackRequired(reason: fallbackReason)
        }

        let config = store.loadConfiguration()

        for attempt in 1...maxFramesToTry {
            do {
                let (cgImage, _) = try await cameraService.captureSingleFrame(timeoutSeconds: 1.2)
                if let analysis = try visionEngine.analyzeFace(
                    in: cgImage,
                    requireAttention: config.requireAttentionDetection
                ) {
                    let result = verifyCandidate(
                        candidateEmbedding: analysis.embedding,
                        liveness: analysis.liveness
                    )
                    if case .authenticated(let user, let similarity, _) = result {
                        let totalMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                        return .authenticated(userName: user, similarity: similarity, elapsedMs: totalMs)
                    }
                    if case .fallbackRequired = result {
                        return result
                    }
                    if attempt == maxFramesToTry {
                        return result
                    }
                }
            } catch {
                if attempt == maxFramesToTry {
                    return .failed(reason: error.localizedDescription, consecutiveFailures: store.loadSecurityState().consecutiveFailures)
                }
            }
        }

        return .failed(reason: "카메라에서 얼굴을 감지할 수 없습니다.", consecutiveFailures: store.loadSecurityState().consecutiveFailures)
    }

    // MARK: - 4. Touch ID / 시스템 암호 Fallback 실행 (LocalAuthentication 연동)

    public func triggerTouchIDOrPasswordFallback(reason: String = "Face ID 인증을 대신하여 Touch ID 또는 암호를 입력해 주세요.") async -> Bool {
        let context = LAContext()
        var authError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            return false
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                resetSecurityPolicyAfterPasswordUnlock()
            }
            return success
        } catch {
            return false
        }
    }

    /// 암호 또는 Touch ID 인증 성공 시 연속 실패 카운터 초기화 및 48시간 타이머 갱신
    public func resetSecurityPolicyAfterPasswordUnlock() {
        let resetState = SecureEnclaveStore.SecurityPolicyState(
            consecutiveFailures: 0,
            lastSuccessfulAuthDate: Date(),
            lastBootTimeVerified: ProcessInfo.processInfo.systemUptime
        )
        store.saveSecurityState(resetState)
    }

    // MARK: - 5. 시뮬레이션/테스트 및 고속 초기 등록 헬퍼

    /// 테스트 또는 카메라 비활성 환경에서도 다각도 표준 얼굴 벡터를 생성·등록할 수 있는 유틸리티
    public func createSyntheticEnrollmentProfile(
        userName: String = NSUserName(),
        isAlternateAppearance: Bool = false,
        seed: Float = 0.42
    ) throws -> FaceProfile {
        var embeddings: [FaceEmbedding] = []
        for (idx, pose) in EnrollmentPose.allCases.enumerated() {
            var vec = [Float](repeating: 0.0, count: 128)
            for i in 0..<128 {
                let angle = Float(i) * 0.17 + seed + Float(idx) * 0.015
                vec[i] = sin(angle) + cos(angle * 0.5)
            }
            embeddings.append(FaceEmbedding(vector: vec, pose: pose, captureQuality: 0.96))
        }

        let profile = FaceProfile(
            userName: userName,
            isAlternateAppearance: isAlternateAppearance,
            embeddings: embeddings
        )
        try store.enrollProfile(profile)
        resetSecurityPolicyAfterPasswordUnlock()
        return profile
    }
}

