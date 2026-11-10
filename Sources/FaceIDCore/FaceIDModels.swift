import Foundation
import CoreGraphics

/// Face ID 등록 단계 (iPhone 원형 다각도 스캔 방식)
public enum EnrollmentPose: String, CaseIterable, Codable, Sendable {
    case center = "정면 응시"
    case left = "고개를 왼쪽으로 살짝 회전"
    case right = "고개를 오른쪽으로 살짝 회전"
    case up = "고개를 위쪽으로 살짝 들기"
    case down = "고개를 아래쪽으로 살짝 숙이기"

    public var instruction: String {
        switch self {
        case .center: return "카메라 정면을 바라봐 주세요."
        case .left: return "원형 가이드를 따라 고개를 천천히 왼쪽으로 돌려주세요."
        case .right: return "원형 가이드를 따라 고개를 천천히 오른쪽으로 돌려주세요."
        case .up: return "원형 가이드를 따라 고개를 살짝 위로 들어주세요."
        case .down: return "원형 가이드를 따라 고개를 살짝 아래로 숙여주세요."
        }
    }
}

/// 128차원 정규화 얼굴 특징 벡터 (Face Embedding)
public struct FaceEmbedding: Codable, Equatable, Sendable {
    public let vector: [Float]
    public let pose: EnrollmentPose
    public let captureQuality: Float
    public let timestamp: Date

    public init(vector: [Float], pose: EnrollmentPose = .center, captureQuality: Float = 1.0, timestamp: Date = Date()) {
        self.vector = FaceEmbedding.l2Normalize(vector)
        self.pose = pose
        self.captureQuality = captureQuality
        self.timestamp = timestamp
    }

    /// L2 정규화 수행 (단위 벡터화)
    public static func l2Normalize(_ v: [Float]) -> [Float] {
        let sumSq = v.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sqrt(max(sumSq, 1e-12))
        return v.map { $0 / norm }
    }

    /// 코사인 유사도 계산 (-1.0 ~ 1.0, 동일 인물일수록 1.0에 수렴)
    public func cosineSimilarity(with other: FaceEmbedding) -> Float {
        guard self.vector.count == other.vector.count, !self.vector.isEmpty else { return 0.0 }
        var dot: Float = 0.0
        for i in 0..<self.vector.count {
            dot += self.vector[i] * other.vector[i]
        }
        return max(-1.0, min(1.0, dot))
    }

    /// 유클리드 거리 계산
    public func euclideanDistance(to other: FaceEmbedding) -> Float {
        guard self.vector.count == other.vector.count, !self.vector.isEmpty else { return .infinity }
        var sum: Float = 0.0
        for i in 0..<self.vector.count {
            let diff = self.vector[i] - other.vector[i]
            sum += diff * diff
        }
        return sqrt(sum)
    }
}

/// 등록된 사용자의 얼굴 프로필 (기본 외모 + 보조 외모 지원)
public struct FaceProfile: Codable, Identifiable, Sendable {
    public var id: UUID
    public var userName: String
    public var isAlternateAppearance: Bool
    public var embeddings: [FaceEmbedding]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        userName: String,
        isAlternateAppearance: Bool = false,
        embeddings: [FaceEmbedding],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userName = userName
        self.isAlternateAppearance = isAlternateAppearance
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 다각도 임베딩들과의 최고 유사도 및 가중 평균 유사도 산출
    public func matchScore(against candidate: FaceEmbedding) -> Float {
        guard !embeddings.isEmpty else { return 0.0 }
        let scores = embeddings.map { $0.cosineSimilarity(with: candidate) }
        guard let maxScore = scores.max() else { return 0.0 }
        let avgScore = scores.reduce(0, +) / Float(scores.count)
        // 최고 유사도 70% + 전체 포즈 평균 유사도 30% 가중 결합
        return (maxScore * 0.7) + (avgScore * 0.3)
    }
}

/// 생체 판별 (Anti-Spoofing / Liveness Detection) 결과
public struct LivenessResult: Sendable, Codable {
    public let isLive: Bool
    public let confidence: Float
    public let eyeAspectRatio: Float
    public let isLookingAtScreen: Bool
    public let textureRealnessScore: Float
    public let failureReason: String?

    public init(
        isLive: Bool,
        confidence: Float,
        eyeAspectRatio: Float,
        isLookingAtScreen: Bool,
        textureRealnessScore: Float,
        failureReason: String? = nil
    ) {
        self.isLive = isLive
        self.confidence = confidence
        self.eyeAspectRatio = eyeAspectRatio
        self.isLookingAtScreen = isLookingAtScreen
        self.textureRealnessScore = textureRealnessScore
        self.failureReason = failureReason
    }
}

/// Face ID 인증 상태 (iPhone Dynamic Notch HUD 연동용)
public enum AuthenticationState: Equatable, Sendable {
    case idle
    case scanning
    case verifyingLiveness
    case authenticated(userName: String, similarity: Float, elapsedMs: Double)
    case failed(reason: String, consecutiveFailures: Int)
    case fallbackRequired(reason: FallbackReason)
}

/// iPhone Face ID 보안 정책에 따른 패스워드/Touch ID Fallback 사유
public enum FallbackReason: String, Codable, Sendable {
    case maxConsecutiveFailures = "연속 5회 얼굴 인식 실패로 인해 암호 또는 Touch ID 입력이 필요합니다."
    case initialLoginAfterBoot = "시스템 재부팅 후 최초 인증에는 암호 입력이 필요합니다."
    case expired48Hours = "48시간 이상 Face ID로 잠금 해제하지 않아 암호 확인이 필요합니다."
    case noEnrolledFace = "등록된 Face ID 데이터가 없습니다. 먼저 얼굴을 등록해 주세요."
    case livenessSpoofDetected = "위변조(사진/화면 재생) 시도가 감지되어 보안 잠금이 활성화되었습니다."
}

/// Face ID 환경설정 모델
public struct FaceIDConfiguration: Codable, Sendable {
    public var isEnabledForScreenUnlock: Bool
    public var isEnabledForSudo: Bool
    public var requireAttentionDetection: Bool
    public var enableLowLightScreenAssist: Bool
    public var autoLockOnWalkAway: Bool
    public var similarityThreshold: Float
    public var maxFailureAttempts: Int

    public init(
        isEnabledForScreenUnlock: Bool = true,
        isEnabledForSudo: Bool = true,
        requireAttentionDetection: Bool = true,
        enableLowLightScreenAssist: Bool = true,
        autoLockOnWalkAway: Bool = false,
        similarityThreshold: Float = 0.85,
        maxFailureAttempts: Int = 5
    ) {
        self.isEnabledForScreenUnlock = isEnabledForScreenUnlock
        self.isEnabledForSudo = isEnabledForSudo
        self.requireAttentionDetection = requireAttentionDetection
        self.enableLowLightScreenAssist = enableLowLightScreenAssist
        self.autoLockOnWalkAway = autoLockOnWalkAway
        self.similarityThreshold = similarityThreshold
        self.maxFailureAttempts = maxFailureAttempts
    }
}

