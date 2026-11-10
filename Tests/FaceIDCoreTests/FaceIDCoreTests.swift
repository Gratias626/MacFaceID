import XCTest
@testable import FaceIDCore

final class FaceIDCoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: SecureEnclaveStore!
    private var controller: FaceIDAuthenticationController!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacFaceIDTests_\(UUID().uuidString)", isDirectory: true)
        store = SecureEnclaveStore(customDirectory: tempDir)
        controller = FaceIDAuthenticationController(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 1. 128D 임베딩 L2 정규화 및 코사인 유사도 검증
    func testEmbeddingNormalizationAndCosineSimilarity() {
        let rawA: [Float] = (0..<128).map { Float($0) * 0.1 + 1.0 }
        let rawB: [Float] = rawA.map { $0 * 2.5 } // 스케일만 다른 동일 방향 벡터
        let rawDifferent: [Float] = (0..<128).map { ($0 % 2 == 0) ? 1.0 : -1.0 }

        let embA = FaceEmbedding(vector: rawA, pose: .center)
        let embB = FaceEmbedding(vector: rawB, pose: .center)
        let embDiff = FaceEmbedding(vector: rawDifferent, pose: .left)

        // 동일 인물(스케일 불변) 코사인 유사도는 1.0이어야 함
        XCTAssertEqual(embA.cosineSimilarity(with: embB), 1.0, accuracy: 1e-5)
        // 전혀 다른 얼굴 벡터와의 유사도는 기준치(0.85)보다 훨씬 낮아야 함
        XCTAssertLessThan(embA.cosineSimilarity(with: embDiff), 0.3)
    }

    /// 2. Secure Enclave AES-GCM 256-bit 암호화 저장 및 복호화 무결성 검증
    func testSecureEnclaveStoreEncryptionRoundTrip() throws {
        let profile = try controller.createSyntheticEnrollmentProfile(userName: "testuser", isAlternateAppearance: false, seed: 0.77)
        let loaded = try store.loadProfiles()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.userName, "testuser")
        XCTAssertEqual(loaded.first?.embeddings.count, EnrollmentPose.allCases.count)
        XCTAssertEqual(loaded.first?.embeddings.first?.vector, profile.embeddings.first?.vector)
    }

    /// 3. 기본 외모 + 보조 외모(Alternate Appearance) 등록 및 500ms 이내 초고속 인증 성공 검증
    func testAuthenticationSuccessAndSpeedUnder500ms() throws {
        let primary = try controller.createSyntheticEnrollmentProfile(userName: "entlab", isAlternateAppearance: false, seed: 0.33)
        let alternate = try controller.createSyntheticEnrollmentProfile(userName: "entlab", isAlternateAppearance: true, seed: 1.44)

        let liveResult = LivenessResult(
            isLive: true,
            confidence: 0.98,
            eyeAspectRatio: 0.27,
            isLookingAtScreen: true,
            textureRealnessScore: 0.94
        )

        // 기본 외모 후보 벡터로 인증
        let candidateFromPrimary = primary.embeddings[0]
        let authState1 = controller.verifyCandidate(candidateEmbedding: candidateFromPrimary, liveness: liveResult)

        guard case .authenticated(let user1, let similarity1, let elapsedMs1) = authState1 else {
            XCTFail("기본 외모 인증이 성공해야 합니다. 현재 상태: \(authState1)")
            return
        }
        XCTAssertEqual(user1, "entlab")
        XCTAssertGreaterThan(similarity1, 0.95)
        XCTAssertLessThan(elapsedMs1, 500.0, "인증 소요 시간은 500ms 이하여야 합니다.")

        // 보조 외모(안경/마스크 등) 후보 벡터로 인증
        let candidateFromAlt = alternate.embeddings[2]
        let authState2 = controller.verifyCandidate(candidateEmbedding: candidateFromAlt, liveness: liveResult)
        guard case .authenticated(_, let similarity2, _) = authState2 else {
            XCTFail("보조 외모 인증이 성공해야 합니다.")
            return
        }
        XCTAssertGreaterThan(similarity2, 0.95)
    }

    /// 4. Liveness Spoofing(사진/영상 위변조 또는 시선 미주시) 차단 테스트
    func testAntiSpoofingBlocks2DPhotoAttack() throws {
        let primary = try controller.createSyntheticEnrollmentProfile(userName: "entlab", isAlternateAppearance: false)
        let validVector = primary.embeddings[0]

        // 얼굴 벡터는 일치하지만 2D 사진 공격으로 판별된 경우 (isLive == false)
        let spoofLiveness = LivenessResult(
            isLive: false,
            confidence: 0.20,
            eyeAspectRatio: 0.05,
            isLookingAtScreen: false,
            textureRealnessScore: 0.30,
            failureReason: "2D 사진 또는 화면 재생 위변조(Spoofing)가 의심됩니다."
        )

        let state = controller.verifyCandidate(candidateEmbedding: validVector, liveness: spoofLiveness)
        if case .failed(let reason, let count) = state {
            XCTAssertTrue(reason.contains("위변조"))
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("위변조 시도는 반드시 차단되어야 합니다.")
        }
    }

    /// 5. iPhone Face ID 보안 정책: 연속 5회 실패 시 Touch ID / 패스워드 Fallback 강제 전환 검증
    func testFiveConsecutiveFailuresTriggerFallback() throws {
        _ = try controller.createSyntheticEnrollmentProfile(userName: "entlab", seed: 0.1)

        // 타인의 얼굴 벡터 생성
        let impostorVector = FaceEmbedding(
            vector: (0..<128).map { ($0 % 2 == 0) ? -0.9 : 0.8 },
            pose: .center
        )
        let liveResult = LivenessResult(
            isLive: true,
            confidence: 0.95,
            eyeAspectRatio: 0.26,
            isLookingAtScreen: true,
            textureRealnessScore: 0.92
        )

        // 1~4회 실패 시 .failed 반환
        for expectedCount in 1...4 {
            let res = controller.verifyCandidate(candidateEmbedding: impostorVector, liveness: liveResult)
            if case .failed(_, let failures) = res {
                XCTAssertEqual(failures, expectedCount)
            } else {
                XCTFail("\(expectedCount)회차에는 일반 실패 상태여야 합니다.")
            }
        }

        // 5회차 실패 시 즉시 .fallbackRequired(.maxConsecutiveFailures) 전환
        let fifthResult = controller.verifyCandidate(candidateEmbedding: impostorVector, liveness: liveResult)
        XCTAssertEqual(fifthResult, .fallbackRequired(reason: .maxConsecutiveFailures))

        // 이후 본인 얼굴을 들이밀어도 암호/Touch ID를 한 번 입력하기 전까지는 잠금 유지
        let profiles = try store.loadProfiles()
        let ownerEmbedding = profiles[0].embeddings[0]
        let lockedResult = controller.verifyCandidate(candidateEmbedding: ownerEmbedding, liveness: liveResult)
        XCTAssertEqual(lockedResult, .fallbackRequired(reason: .maxConsecutiveFailures))

        // 암호/Touch ID 인증 통과 후에는 다시 정상적으로 Face ID 작동
        controller.resetSecurityPolicyAfterPasswordUnlock()
        let unlockedResult = controller.verifyCandidate(candidateEmbedding: ownerEmbedding, liveness: liveResult)
        if case .authenticated = unlockedResult {
            // 통과
        } else {
            XCTFail("암호 해제 후에는 다시 Face ID 인증이 가능해야 합니다.")
        }
    }
}

