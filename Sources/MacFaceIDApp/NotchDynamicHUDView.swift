import SwiftUI
import AppKit
import FaceIDCore

/// MacBook Air M2 상단 노치(Notch) 주변에 iPhone Dynamic Island / Face ID 스타일의 인증 애니메이션을 표시하는 HUD 뷰
public struct NotchDynamicHUDView: View {
    public let authState: AuthenticationState
    public let lowLightAssistActive: Bool

    public init(authState: AuthenticationState, lowLightAssistActive: Bool = false) {
        self.authState = authState
        self.lowLightAssistActive = lowLightAssistActive
    }

    public var body: some View {
        ZStack {
            // 저조도 환경 시 화면 보조 조명 (Face Illumination 링)
            if lowLightAssistActive {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 12)
                    .shadow(color: .white, radius: 24)
                    .padding(4)
            }

            HStack(spacing: 14) {
                statusIcon
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(subtitleText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(width: 320, height: 64)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.92))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(borderColor.opacity(0.65), lineWidth: 1.5)
                    )
                    .shadow(color: borderColor.opacity(0.35), radius: 14, x: 0, y: 6)
            )
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch authState {
        case .idle:
            Image(systemName: "faceid")
                .foregroundColor(.cyan)
        case .scanning, .verifyingLiveness:
            Image(systemName: "faceid")
                .foregroundColor(.blue)
        case .authenticated:
            Image(systemName: "lock.open.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.orange)
        case .fallbackRequired:
            Image(systemName: "touchid")
                .foregroundColor(.red)
        }
    }

    private var borderColor: Color {
        switch authState {
        case .idle: return .gray
        case .scanning, .verifyingLiveness: return .cyan
        case .authenticated: return .green
        case .failed: return .orange
        case .fallbackRequired: return .red
        }
    }

    private var titleText: String {
        switch authState {
        case .idle:
            return "Face ID 대기 중"
        case .scanning:
            return "Face ID 스캔 중..."
        case .verifyingLiveness:
            return "생체 인증(Liveness) 확인 중..."
        case .authenticated(let user, _, let ms):
            return String(format: "잠금 해제됨 (%@ · %.0fms)", user, ms)
        case .failed:
            return "Face ID 인식 실패"
        case .fallbackRequired:
            return "Touch ID 또는 암호 필요"
        }
    }

    private var subtitleText: String {
        switch authState {
        case .idle:
            return "MacBook Air M2 FaceTime HD 카메라 준비됨"
        case .scanning:
            return "카메라를 바라봐 주세요 (M2 Neural Engine 가속)"
        case .verifyingLiveness:
            return "시선 주시 및 3D 위변조 여부 판별 중"
        case .authenticated(_, let similarity, _):
            return String(format: "특징 벡터 일치도 %.1f%% · Touch ID 권한 승인", similarity * 100)
        case .failed(let reason, _):
            return reason
        case .fallbackRequired(let reason):
            return reason.rawValue
        }
    }
}

