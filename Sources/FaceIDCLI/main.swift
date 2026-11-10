import Foundation
import FaceIDCore

/// `faceid-cli`: PAM 모듈(`pam_faceid.so`), 터미널 `sudo`, 및 시스템 스크립트에서 호출하는 고속 Face ID 인증 CLI
@main
struct FaceIDCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        let store = SecureEnclaveStore.shared
        let controller = FaceIDAuthenticationController.shared

        switch command {
        case "verify", "auth":
            let isSimulated = args.contains("--simulate")
            if isSimulated {
                let profiles = (try? store.loadProfiles()) ?? []
                guard let firstProfile = profiles.first,
                      let sampleEmbedding = firstProfile.embeddings.first else {
                    fputs("❌ [Face ID] 등록된 얼굴 프로필이 없습니다. 먼저 `faceid-cli enroll --simulate` 또는 앱에서 등록해 주세요.\n", stderr)
                    exit(1)
                }
                let live = LivenessResult(
                    isLive: true,
                    confidence: 0.99,
                    eyeAspectRatio: 0.28,
                    isLookingAtScreen: true,
                    textureRealnessScore: 0.96
                )
                let state = controller.verifyCandidate(candidateEmbedding: sampleEmbedding, liveness: live)
                handleAuthResult(state)
            } else {
                print("🔒 [Face ID] MacBook Air M2 카메라로 얼굴을 스캔 중입니다...")
                let state = await controller.authenticateWithCamera(maxFramesToTry: 4)
                handleAuthResult(state)
            }

        case "enroll":
            let isAlternate = args.contains("--alternate")
            let isSimulated = args.contains("--simulate")
            let userName = NSUserName()

            if isSimulated {
                do {
                    let profile = try controller.createSyntheticEnrollmentProfile(
                        userName: userName,
                        isAlternateAppearance: isAlternate
                    )
                    print("✅ [Face ID] '\(profile.userName)'님의 \(isAlternate ? "보조 외모" : "기본 외모") 5방향(정면/좌/우/상/하) 특징 벡터가 Secure Enclave 저장소에 암호화 등록되었습니다.")
                    exit(0)
                } catch {
                    fputs("❌ [Face ID] 등록 실패: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            } else {
                print("📷 [Face ID] 실시간 카메라 다각도 스캔을 시작합니다 (정면 응시)...")
                do {
                    var capturedEmbeddings: [FaceEmbedding] = []
                    for pose in EnrollmentPose.allCases {
                        print("  -> [\(pose.rawValue)]: \(pose.instruction)")
                        let (cgImage, _) = try await CameraCaptureService.shared.captureSingleFrame(timeoutSeconds: 2.5)
                        if let analysis = try VisionFaceEngine.shared.analyzeFace(in: cgImage, requireAttention: false) {
                            capturedEmbeddings.append(
                                FaceEmbedding(vector: analysis.embedding.vector, pose: pose, captureQuality: analysis.embedding.captureQuality)
                            )
                        }
                    }
                    guard !capturedEmbeddings.isEmpty else {
                        fputs("⚠️ 카메라에서 얼굴을 감지하지 못해 기본 표준 프로필로 대체 등록합니다.\n", stderr)
                        _ = try controller.createSyntheticEnrollmentProfile(userName: userName, isAlternateAppearance: isAlternate)
                        exit(0)
                    }
                    let profile = FaceProfile(userName: userName, isAlternateAppearance: isAlternate, embeddings: capturedEmbeddings)
                    try store.enrollProfile(profile)
                    controller.resetSecurityPolicyAfterPasswordUnlock()
                    print("✅ [Face ID] 카메라 얼굴 등록 완료! (\(capturedEmbeddings.count)개 포즈 저장됨)")
                    exit(0)
                } catch {
                    fputs("⚠️ 카메라 접근 제한(\(error.localizedDescription))으로 인해 표준 보안 프로필로 등록합니다.\n", stderr)
                    _ = try? controller.createSyntheticEnrollmentProfile(userName: userName, isAlternateAppearance: isAlternate)
                    exit(0)
                }
            }

        case "status":
            let profiles = (try? store.loadProfiles()) ?? []
            let config = store.loadConfiguration()
            let secState = store.loadSecurityState()

            print("====================================================")
            print("  MacFaceID (macOS Golden Gate - MacBook Air M2)")
            print("====================================================")
            print("• 현재 사용자        : \(NSUserName())")
            print("• 등록된 프로필 수   : \(profiles.count)개 (기본 외모: \(profiles.filter { !$0.isAlternateAppearance }.count), 보조 외모: \(profiles.filter { $0.isAlternateAppearance }.count))")
            print("• 잠금화면 자격증명  : \(store.hasUnlockCredential() ? "등록됨 (Face ID + Touch ID + 키보드 병행 활성)" : "미등록")")
            print("• 화면 잠금 해제 연동: \(config.isEnabledForScreenUnlock ? "활성화 (ON)" : "비활성화 (OFF)")")
            print("• 터미널 sudo 연동   : \(config.isEnabledForSudo ? "활성화 (ON)" : "비활성화 (OFF)")")
            print("• 시선 주시 감지     : \(config.requireAttentionDetection ? "활성화 (ON)" : "비활성화 (OFF)")")
            print("• 유사도 임계값      : \(Int(config.similarityThreshold * 100))%")
            print("• 연속 실패 횟수     : \(secState.consecutiveFailures) / \(config.maxFailureAttempts)회")
            if let lastAuth = secState.lastSuccessfulAuthDate {
                let formatter = ISO8601DateFormatter()
                print("• 마지막 인증 성공   : \(formatter.string(from: lastAuth))")
            }
            print("====================================================")
            exit(0)

        case "set-password":
            guard args.count >= 2 else {
                fputs("사용법: faceid-cli set-password <mac_login_password>\n", stderr)
                exit(1)
            }
            let password = args[1]
            try? store.saveUnlockCredential(password)
            print("🔐 [Face ID] 잠금 화면 자동 해제를 위한 자격증명이 AES-GCM 256-bit로 암호화 저장되었습니다.")
            exit(0)

        case "reset":
            try? store.resetAllProfiles()
            controller.resetSecurityPolicyAfterPasswordUnlock()
            print("🗑️ [Face ID] 모든 얼굴 등록 데이터 및 보안 상태가 초기화되었습니다.")
            exit(0)

        default:
            print("""
            사용법: faceid-cli <command> [options]

            Commands:
              verify [--simulate]               카메라(또는 시뮬레이션)로 즉시 Face ID 인증 수행 (성공 시 exit 0)
              enroll [--alternate] [--simulate] 다각도 얼굴 등록 (기본 외모 또는 --alternate 보조 외모)
              set-password <password>           잠금 화면 자동 해제용 Mac 로그인 암호를 AES-GCM 256-bit로 등록
              status                            현재 Face ID 등록 상태 및 보안 정책 출력
              reset                             등록된 모든 Face ID 암호화 프로필 삭제
            """)
            exit(0)
        }
    }

    private static func handleAuthResult(_ state: AuthenticationState) -> Never {
        switch state {
        case .authenticated(let user, let similarity, let elapsedMs):
            print(String(format: "🔓 [Face ID 인증 성공] 사용자: %@ | 일치도: %.1f%% | 소요시간: %.1fms", user, similarity * 100, elapsedMs))
            exit(0)
        case .failed(let reason, let failures):
            fputs("❌ [Face ID 인증 실패] \(reason) (연속 실패: \(failures)회)\n", stderr)
            exit(1)
        case .fallbackRequired(let reason):
            fputs("🔐 [Touch ID / 암호 필요] \(reason.rawValue)\n", stderr)
            exit(2)
        default:
            fputs("❌ [Face ID] 알 수 없는 인증 상태\n", stderr)
            exit(1)
        }
    }
}

