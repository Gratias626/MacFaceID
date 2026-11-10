import Foundation
import AppKit
import CoreGraphics

/// macOS Golden Gate 시스템 이벤트(화면 잠금, 슬립 깨우기, 자리 비움 감지) 연동 데몬 매니저
/// Touch ID와 동일하게 화면이 켜지거나 잠금 해제 요청이 발생할 때 즉시 Face ID 인증을 수행합니다.
public final class SystemIntegrationDaemon: @unchecked Sendable {
    public static let shared = SystemIntegrationDaemon()

    private let authController: FaceIDAuthenticationController
    private let store: SecureEnclaveStore
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isScreenCurrentlyLocked: Bool = false
    public var onAuthStateChanged: ((AuthenticationState) -> Void)?

    public init(
        authController: FaceIDAuthenticationController = .shared,
        store: SecureEnclaveStore = .shared
    ) {
        self.authController = authController
        self.store = store
    }

    /// 시스템 슬립 깨우기(Wake from Sleep) 및 화면 잠금 이벤트 모니터링 시작
    public func startMonitoringSystemEvents() {
        stopMonitoringSystemEvents()

        let wsCenter = NSWorkspace.shared.notificationCenter

        // 1. 맥북 덮개를 열거나 슬립에서 깨어날 때 Touch ID / 키보드 입력을 가로막지 않고 병렬로 Face ID 스캔 트리거
        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerParallelFaceIDUnlockIfNeeded()
        }

        // 2. 디스플레이가 다시 켜질 때 병렬 Face ID 트리거
        let screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerParallelFaceIDUnlockIfNeeded()
        }

        workspaceObservers.append(contentsOf: [wakeObserver, screenWakeObserver])

        // 3. macOS 화면 잠금/해제 DistributedNotification 감지 (Touch ID & 키보드 암호 병행 연동)
        let distCenter = DistributedNotificationCenter.default()
        let lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenCurrentlyLocked = true
            self?.onAuthStateChanged?(.idle)
        }

        // 사용자가 Touch ID 또는 키보드 암호 직접 입력으로 잠금을 해제한 경우 -> 즉시 보안 정책 카운터(5회 실패/48시간 타이머) 리셋
        let unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isScreenCurrentlyLocked = false
            self.authController.resetSecurityPolicyAfterPasswordUnlock()
        }
        distributedObservers.append(contentsOf: [lockObserver, unlockObserver])

        // 4. 부재 시 자동 화면 잠금 (Auto-Lock on Walk Away) 타이머 모니터링
        startWalkAwayAutoLockTimerIfNeeded()
    }

    /// 잠금 화면에서 Touch ID 및 키보드 암호 입력창을 그대로 활성화한 채 백그라운드에서 병렬로 Face ID 인증 수행
    private func triggerParallelFaceIDUnlockIfNeeded() {
        let config = store.loadConfiguration()
        guard config.isEnabledForScreenUnlock else { return }
        Task {
            self.onAuthStateChanged?(.scanning)
            let result = await self.authController.authenticateWithCamera()
            self.onAuthStateChanged?(result)
            if case .authenticated = result {
                self.submitUnlockCredentialIfScreenLockedAndIdle()
            }
        }
    }

    /// 사용자가 키보드를 직접 타이핑 중이 아니고 화면이 잠겨 있을 때만 저장된 암호화 자격증명으로 잠금 화면 자동 해제
    private func submitUnlockCredentialIfScreenLockedAndIdle() {
        guard isScreenCurrentlyLocked else { return }
        // 최근 2.0초 이내 키보드 입력이 있었다면 사용자가 직접 암호를 입력 중이므로 간섭하지 않음
        let secondsSinceKeyPress = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard secondsSinceKeyPress > 2.0 else { return }
        guard let password = store.loadUnlockCredential(), !password.isEmpty else { return }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let utf16Chars = Array(password.utf16)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        // Return 키 전송 (virtualKey 36)
        if let retDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
           let retUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            retDown.post(tap: .cghidEventTap)
            retUp.post(tap: .cghidEventTap)
        }
    }

    private var walkAwayTimer: Timer?

    private func startWalkAwayAutoLockTimerIfNeeded() {
        walkAwayTimer?.invalidate()
        walkAwayTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let config = self.store.loadConfiguration()
            guard config.autoLockOnWalkAway else { return }

            Task {
                // 카메라로 사용자 재석 여부 경량 확인
                if let (cgImage, _) = try? await CameraCaptureService.shared.captureSingleFrame(timeoutSeconds: 1.0) {
                    let faceDetected = (try? VisionFaceEngine.shared.analyzeFace(in: cgImage, requireAttention: false)) != nil
                    if !faceDetected {
                        self.lockScreenNow()
                    }
                }
            }
        }
    }

    /// 자리 비움 감지 시 즉시 macOS 화면 잠금 실행 (`pmset displaysleepnow`)
    public func lockScreenNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    public func stopMonitoringSystemEvents() {
        walkAwayTimer?.invalidate()
        walkAwayTimer = nil

        let wsCenter = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            wsCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        let distCenter = DistributedNotificationCenter.default()
        for obs in distributedObservers {
            distCenter.removeObserver(obs)
        }
        distributedObservers.removeAll()
    }
}

