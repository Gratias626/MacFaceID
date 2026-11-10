import Foundation
import FaceIDCore

@main
struct TestRunner {
    static func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("❌ TEST FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        print("🧪 [FaceIDCoreTests] 자동화 검증 스위트 시작...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacFaceIDTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SecureEnclaveStore(customDirectory: tempDir)
        let controller = FaceIDAuthenticationController(store: store)

        // 1. 128D 임베딩 L2 정규화 및 코사인 유사도 검증
        let rawA: [Float] = (0..<128).map { Float($0) * 0.1 + 1.0 }
        let rawB: [Float] = rawA.map { $0 * 2.5 }
        let rawDiff: [Float] = (0..<128).map { ($0 % 2 == 0) ? 1.0 : -1.0 }

        let embA = FaceEmbedding(vector: rawA, pose: .center)
        let embB = FaceEmbedding(vector: rawB, pose: .center)
        let embDiff = FaceEmbedding(vector: rawDiff, pose: .left)

        assert(abs(embA.cosineSimilarity(with: embB) - 1.0) < 1e-5, "동일 방향 벡터의 코사인 유사도는 1.0이어야 합니다.")
        assert(embA.cosineSimilarity(with: embDiff) < 0.3, "타인 얼굴 벡터와의 유사도는 기준치 미만이어야 합니다.")
        print("  ✅ [Test 1/5] 128D 얼굴 임베딩 정규화 및 코사인 유사도 수학적 검증 통과")

        // 2. Secure Enclave AES-GCM 256-bit 암호화/복호화 무결성 검증
        let enrolled = try controller.createSyntheticEnrollmentProfile(userName: "entlab", isAlternateAppearance: false, seed: 0.77)
        let loaded = try store.loadProfiles()
        assert(loaded.count == 1, "암호화 저장 후 1개의 프로필이 로드되어야 합니다.")
        assert(loaded.first?.embeddings.count == EnrollmentPose.allCases.count, "5방향 포즈 임베딩이 모두 복호화되어야 합니다.")
        assert(loaded.first?.embeddings.first?.vector == enrolled.embeddings.first?.vector, "AES-GCM 복호화 후 벡터가 일치해야 합니다.")
        try store.saveUnlockCredential("TestLockScreenPass!2026")
        assert(store.hasUnlockCredential(), "잠금 화면 자동 해제 자격증명이 암호화 저장되어야 합니다.")
        assert(store.loadUnlockCredential() == "TestLockScreenPass!2026", "잠금 화면 자격증명 복호화 결과가 일치해야 합니다.")
        print("  ✅ [Test 2/5] Secure Enclave AES-GCM 256-bit 암호화 저장소 무결성 검증 통과")

        // 3. 기본 외모 + 보조 외모(Alternate Appearance) 등록 및 초고속(500ms 이하) 인증 검증
        let altProfile = try controller.createSyntheticEnrollmentProfile(userName: "entlab", isAlternateAppearance: true, seed: 1.44)
        let liveResult = LivenessResult(
            isLive: true,
            confidence: 0.99,
            eyeAspectRatio: 0.28,
            isLookingAtScreen: true,
            textureRealnessScore: 0.96
        )

        let state1 = controller.verifyCandidate(candidateEmbedding: enrolled.embeddings[0], liveness: liveResult)
        guard case .authenticated(let user1, let sim1, let ms1) = state1 else {
            assert(false, "기본 외모 인증이 성공해야 합니다.")
            return
        }
        assert(user1 == "entlab" && sim1 > 0.95 && ms1 < 500.0, "500ms 이내 고속 인증을 만족해야 합니다.")

        let state2 = controller.verifyCandidate(candidateEmbedding: altProfile.embeddings[2], liveness: liveResult)
        guard case .authenticated(_, let sim2, _) = state2 else {
            assert(false, "보조 외모 인증이 성공해야 합니다.")
            return
        }
        assert(sim2 > 0.95, "보조 외모 유사도가 95% 이상이어야 합니다.")
        print(String(format: "  ✅ [Test 3/5] 기본 외모 & 보조 외모 초고속 매칭 통과 (소요시간: %.3fms, 유사도: %.1f%%)", ms1, sim1 * 100))

        // 4. Anti-Spoofing (2D 사진 / 시선 미주시 공격 차단) 검증
        let spoofLiveness = LivenessResult(
            isLive: false,
            confidence: 0.20,
            eyeAspectRatio: 0.05,
            isLookingAtScreen: false,
            textureRealnessScore: 0.30,
            failureReason: "2D 사진 또는 화면 재생 위변조(Spoofing)가 의심됩니다."
        )
        let spoofState = controller.verifyCandidate(candidateEmbedding: enrolled.embeddings[0], liveness: spoofLiveness)
        if case .failed(let reason, let failCount) = spoofState {
            assert(reason.contains("위변조") && failCount == 1, "위변조 공격은 즉시 거부되고 실패 횟수가 증가해야 합니다.")
        } else {
            assert(false, "위변조 공격이 차단되지 않았습니다.")
        }
        controller.resetSecurityPolicyAfterPasswordUnlock()
        print("  ✅ [Test 4/5] RGB Liveness & Attention Detection 위변조(사진/화면) 차단 검증 통과")

        // 5. 연속 5회 실패 시 Touch ID / 패스워드 Fallback 강제 전환 정책 검증
        let impostor = FaceEmbedding(vector: (0..<128).map { ($0 % 2 == 0) ? -0.9 : 0.8 }, pose: .center)
        for expected in 1...4 {
            let res = controller.verifyCandidate(candidateEmbedding: impostor, liveness: liveResult)
            if case .failed(_, let cnt) = res {
                assert(cnt == expected, "연속 실패 카운트가 일치해야 합니다.")
            } else {
                assert(false, "1~4회 실패는 .failed 상태여야 합니다.")
            }
        }
        let fifth = controller.verifyCandidate(candidateEmbedding: impostor, liveness: liveResult)
        assert(fifth == .fallbackRequired(reason: .maxConsecutiveFailures), "5회 실패 시 즉시 Touch ID/암호 Fallback으로 전환되어야 합니다.")

        // 잠금 상태에서 정상 얼굴을 제시해도 암호 입력 전까지 차단 유지 확인
        let lockedTry = controller.verifyCandidate(candidateEmbedding: enrolled.embeddings[0], liveness: liveResult)
        assert(lockedTry == .fallbackRequired(reason: .maxConsecutiveFailures), "암호 해제 전까지는 Face ID가 비활성화되어야 합니다.")

        // 암호 입력(Fallback) 완료 후 정상 복구 확인
        controller.resetSecurityPolicyAfterPasswordUnlock()
        let unlockedTry = controller.verifyCandidate(candidateEmbedding: enrolled.embeddings[0], liveness: liveResult)
        if case .authenticated = unlockedTry {
            print("  ✅ [Test 5/5] 연속 5회 실패 시 Touch ID/암호 Fallback 잠금 및 복구 정책 검증 통과")
        } else {
            assert(false, "암호 해제 후 Face ID가 복구되어야 합니다.")
        }

        print("🎉 모든 FaceIDCore 단위 테스트(5/5)가 100% 통과했습니다!")
    }
}

