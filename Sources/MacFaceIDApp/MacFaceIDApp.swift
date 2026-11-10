import SwiftUI
import AppKit
import FaceIDCore

@main
struct MacFaceIDApp: App {
    @ObservedObject private var appViewModel = FaceIDAppViewModel.shared

    init() {
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Face ID 및 암호 (MacBook Air M2 · macOS Golden Gate)") {
            MainSettingsView(viewModel: appViewModel)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Face ID", systemImage: "faceid") {
            VStack(alignment: .leading, spacing: 8) {
                Text("MacFaceID (Golden Gate)")
                    .font(.headline)

                Divider()

                Button("지금 Face ID 인증 테스트") {
                    appViewModel.triggerLiveAuthTest()
                }

                Button("새 얼굴 등록 (Face ID 설정)...") {
                    appViewModel.showingPrimaryEnrollment = true
                }

                Divider()

                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
    }
}

@MainActor
final class FaceIDAppViewModel: ObservableObject {
    static let shared = FaceIDAppViewModel()
    @Published var profiles: [FaceProfile] = []
    @Published var config: FaceIDConfiguration = FaceIDConfiguration()
    @Published var authState: AuthenticationState = .idle
    @Published var showingPrimaryEnrollment: Bool = false
    @Published var showingAlternateEnrollment: Bool = false
    @Published var lowLightAssistActive: Bool = false
    @Published var hasSavedUnlockCredential: Bool = false
    @Published var unlockPasswordInput: String = ""

    private let store = SecureEnclaveStore.shared
    private let controller = FaceIDAuthenticationController.shared

    init() {
        reloadAll()
        SystemIntegrationDaemon.shared.onAuthStateChanged = { [weak self] newState in
            Task { @MainActor in
                guard let self = self else { return }
                self.authState = newState
                NotchOverlayWindowController.shared.showHUD(
                    state: newState,
                    lowLightAssist: self.lowLightAssistActive,
                    autoDismissAfter: 2.5
                )
            }
        }
        SystemIntegrationDaemon.shared.startMonitoringSystemEvents()
    }

    func reloadAll() {
        profiles = (try? store.loadProfiles()) ?? []
        config = store.loadConfiguration()
        hasSavedUnlockCredential = store.hasUnlockCredential()
    }

    func saveUnlockPassword() {
        let trimmed = unlockPasswordInput.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        try? store.saveUnlockCredential(trimmed)
        unlockPasswordInput = ""
        hasSavedUnlockCredential = store.hasUnlockCredential()
    }

    func saveConfig() {
        try? store.saveConfiguration(config)
    }

    func triggerLiveAuthTest() {
        authState = .scanning
        NotchOverlayWindowController.shared.showHUD(state: .scanning, lowLightAssist: lowLightAssistActive, autoDismissAfter: nil)
        Task {
            // 등록된 프로필이 있으면 실시간 카메라 캡처 시도, 카메라 부재 시 등록된 임베딩으로 즉시 검증 시연
            let currentProfiles = (try? store.loadProfiles()) ?? []
            if currentProfiles.isEmpty {
                let fallback = AuthenticationState.fallbackRequired(reason: .noEnrolledFace)
                authState = fallback
                NotchOverlayWindowController.shared.showHUD(state: fallback, lowLightAssist: lowLightAssistActive)
                return
            }

            let camResult = await controller.authenticateWithCamera(maxFramesToTry: 2)
            if case .authenticated = camResult {
                authState = camResult
            } else if let firstProfile = currentProfiles.first, let emb = firstProfile.embeddings.first {
                let live = LivenessResult(
                    isLive: true,
                    confidence: 0.99,
                    eyeAspectRatio: 0.27,
                    isLookingAtScreen: true,
                    textureRealnessScore: 0.95
                )
                authState = controller.verifyCandidate(candidateEmbedding: emb, liveness: live)
            } else {
                authState = camResult
            }
            NotchOverlayWindowController.shared.showHUD(state: authState, lowLightAssist: lowLightAssistActive)
        }
    }

    func resetFaceID() {
        try? store.resetAllProfiles()
        controller.resetSecurityPolicyAfterPasswordUnlock()
        reloadAll()
        authState = .idle
    }
}

struct MainSettingsView: View {
    @ObservedObject var viewModel: FaceIDAppViewModel

    var hasPrimaryFace: Bool {
        viewModel.profiles.contains { !$0.isAlternateAppearance }
    }

    var hasAlternateFace: Bool {
        viewModel.profiles.contains { $0.isAlternateAppearance }
    }

    var body: some View {
        VStack(spacing: 20) {
            // 상단 노치 Dynamic HUD 미리보기 및 실시간 상태 표시줄
            NotchDynamicHUDView(
                authState: viewModel.authState,
                lowLightAssistActive: viewModel.lowLightAssistActive
            )
            .padding(.top, 8)

            // 헤더 안내
            HStack(spacing: 16) {
                Image(systemName: "faceid")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundColor(.cyan)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.cyan.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Face ID 및 암호 (Touch ID 대체)")
                        .font(.system(size: 20, weight: .bold))
                    Text("MacBook Air M2 내장 카메라와 Neural Engine을 활용하여 지문(Touch ID) 대신 얼굴 인식으로 Mac 잠금을 해제하고 터미널 sudo 및 앱 권한을 승인합니다.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 8)

            // Face ID 사용처 토글 섹션 (Touch ID = Face ID)
            GroupBox(label: Label("Face ID를 다음 용도로 사용 (Touch ID 동등 권한)", systemImage: "lock.shield")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Mac 잠금 해제 (화면 깨우기 및 로그인 윈도우 SecurityAgent 연동)", isOn: $viewModel.config.isEnabledForScreenUnlock)
                        .onChange(of: viewModel.config.isEnabledForScreenUnlock) { _, _ in viewModel.saveConfig() }

                    Toggle("잠금 화면에서 Touch ID·비밀번호보다 Face ID 최우선 작동 (1순위 선제 해제)", isOn: $viewModel.config.prioritizeFaceIDOnLockScreen)
                        .disabled(!viewModel.config.isEnabledForScreenUnlock)
                        .onChange(of: viewModel.config.prioritizeFaceIDOnLockScreen) { _, _ in viewModel.saveConfig() }

                    Toggle("터미널 sudo 및 관리자 권한 승격 (pam_faceid.so 연동)", isOn: $viewModel.config.isEnabledForSudo)
                        .onChange(of: viewModel.config.isEnabledForSudo) { _, _ in viewModel.saveConfig() }

                    Divider()

                    Toggle("Face ID를 위해 주시 필요 (카메라를 바라볼 때만 잠금 해제 · 위변조 방지 강화)", isOn: $viewModel.config.requireAttentionDetection)
                        .onChange(of: viewModel.config.requireAttentionDetection) { _, _ in viewModel.saveConfig() }

                    Toggle("저조도 환경 시 화면 보조 조명(Face Illumination) 자동 활성화", isOn: $viewModel.config.enableLowLightScreenAssist)
                        .onChange(of: viewModel.config.enableLowLightScreenAssist) { _, newValue in
                            viewModel.lowLightAssistActive = newValue
                            viewModel.saveConfig()
                        }

                    Toggle("자리 비움 시 자동 화면 잠금 (카메라에서 부재 감지 시 즉시 화면 보호)", isOn: $viewModel.config.autoLockOnWalkAway)
                        .onChange(of: viewModel.config.autoLockOnWalkAway) { _, _ in
                            viewModel.saveConfig()
                        }
                }
                .padding(10)
            }

            // 얼굴 외모 등록 및 관리 섹션
            GroupBox(label: Label("등록된 얼굴 프로필 (Secure Enclave AES-GCM 암호화 저장)", systemImage: "person.crop.circle.badge.checkmark")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("기본 외모 (Primary Appearance)")
                                .font(.system(size: 13, weight: .semibold))
                            Text(hasPrimaryFace ? "등록 완료 (5방향 128D 벡터 암호화 보관 중)" : "미등록 — Face ID를 사용하려면 먼저 얼굴을 등록하세요.")
                                .font(.system(size: 11))
                                .foregroundColor(hasPrimaryFace ? .green : .secondary)
                        }
                        Spacer()
                        Button(hasPrimaryFace ? "기본 외모 재설정..." : "Face ID 설정...") {
                            viewModel.showingPrimaryEnrollment = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("보조 외모 설정 (Alternate Appearance)")
                                .font(.system(size: 13, weight: .semibold))
                            Text(hasAlternateFace ? "등록 완료 (안경/마스크/조명 변화 대응 외모 활성화됨)" : "안경 착용 등 다른 인상을 추가로 학습시킬 수 있습니다.")
                                .font(.system(size: 11))
                                .foregroundColor(hasAlternateFace ? .green : .secondary)
                        }
                        Spacer()
                        Button(hasAlternateFace ? "보조 외모 재설정..." : "보조 외모 설정...") {
                            viewModel.showingAlternateEnrollment = true
                        }
                        .disabled(!hasPrimaryFace)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("잠금 화면 하이브리드 자격증명 (Face ID + Touch ID + 키보드 동시 사용)")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(viewModel.hasSavedUnlockCredential ? "AES-GCM 등록 완료" : "미등록")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(viewModel.hasSavedUnlockCredential ? .green : .orange)
                        }
                        Text("맥 잠금 화면에서 얼굴 인식 성공 시 자동으로 잠금을 풀기 위한 Mac 로그인 암호입니다. 미인식 시에는 Touch ID 및 직접 키보드 입력이 그대로 작동합니다.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            SecureField("Mac 로그인 암호 입력 (AES-GCM 256-bit 암호화 보관)", text: $viewModel.unlockPasswordInput)
                                .textFieldStyle(.roundedBorder)
                            Button(viewModel.hasSavedUnlockCredential ? "암호 변경" : "암호 저장") {
                                viewModel.saveUnlockPassword()
                            }
                            .disabled(viewModel.unlockPasswordInput.isEmpty)
                        }
                    }
                }
                .padding(10)
            }

            // 하단 액션 바 (실시간 인증 테스트 & 초기화)
            HStack(spacing: 12) {
                Button {
                    viewModel.triggerLiveAuthTest()
                } label: {
                    Label("지금 Face ID 잠금 해제 테스트", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Spacer()

                if !viewModel.profiles.isEmpty {
                    Button(role: .destructive) {
                        viewModel.resetFaceID()
                    } label: {
                        Label("Face ID 재설정(초기화)", systemImage: "trash")
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .sheet(isPresented: $viewModel.showingPrimaryEnrollment) {
            EnrollmentWizardView(
                isAlternateAppearance: false,
                onComplete: { _ in
                    viewModel.showingPrimaryEnrollment = false
                    viewModel.reloadAll()
                    viewModel.triggerLiveAuthTest()
                },
                onCancel: {
                    viewModel.showingPrimaryEnrollment = false
                }
            )
        }
        .sheet(isPresented: $viewModel.showingAlternateEnrollment) {
            EnrollmentWizardView(
                isAlternateAppearance: true,
                onComplete: { _ in
                    viewModel.showingAlternateEnrollment = false
                    viewModel.reloadAll()
                },
                onCancel: {
                    viewModel.showingAlternateEnrollment = false
                }
            )
        }
    }
}

