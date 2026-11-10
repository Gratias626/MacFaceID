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
    private var isScanningLockScreen: Bool = false
    private var lockScreenPriorityTimer: Timer?
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

        // 3. macOS 화면 잠금/해제 DistributedNotification 감지 (Face ID 1순위 최우선 + Touch ID/암호 후순위 폴백)
        let distCenter = DistributedNotificationCenter.default()
        let lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isScreenCurrentlyLocked = true
            self.onAuthStateChanged?(.idle)
            self.startLockScreenPriorityMonitor()
        }

        // 사용자가 Touch ID 또는 키보드 암호 직접 입력으로 잠금을 해제한 경우 -> 즉시 보안 정책 카운터(5회 실패/48시간 타이머) 리셋
        let unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isScreenCurrentlyLocked = false
            self.stopLockScreenPriorityMonitor()
            self.authController.resetSecurityPolicyAfterPasswordUnlock()
        }
        distributedObservers.append(contentsOf: [lockObserver, unlockObserver])

        // 4. 부재 시 자동 화면 잠금 (Auto-Lock on Walk Away) 타이머 모니터링
        startWalkAwayAutoLockTimerIfNeeded()
    }

    /// 잠금 화면이 활성화된 동안 사용자 접근(키보드 깨우기/트랙패드 이동) 시 Touch ID·암호 입력보다 먼저 Face ID를 1순위로 즉시 실행
    private func startLockScreenPriorityMonitor() {
        stopLockScreenPriorityMonitor()
        let config = store.loadConfiguration()
        guard config.isEnabledForScreenUnlock && config.prioritizeFaceIDOnLockScreen else { return }

        lockScreenPriorityTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isMacScreenLocked(), !self.isScanningLockScreen else { return }
            // 잠금 화면에서 마우스 이동이나 키 입력 등 깨우기 신호가 감지되면 즉시 Face ID를 최우선 실행
            let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
            if idleSeconds < 1.2 {
                self.triggerParallelFaceIDUnlockIfNeeded()
            }
        }
    }

    private func stopLockScreenPriorityMonitor() {
        lockScreenPriorityTimer?.invalidate()
        lockScreenPriorityTimer = nil
    }

    /// 잠금 화면에서 Touch ID 및 비밀번호 입력보다 Face ID를 1순위로 선제 수행하고, 미인식 시에만 Touch ID/비밀번호로 폴백
    private func triggerParallelFaceIDUnlockIfNeeded() {
        let config = store.loadConfiguration()
        guard config.isEnabledForScreenUnlock, !isScanningLockScreen else { return }
        isScanningLockScreen = true

        Task(priority: .high) {
            defer { self.isScanningLockScreen = false }
            self.onAuthStateChanged?(.scanning)
            let result = await self.authController.authenticateWithCamera(maxFramesToTry: 3)
            self.onAuthStateChanged?(result)
            if case .authenticated = result {
                self.submitUnlockCredentialIfScreenLockedAndIdle(prioritizeFaceID: config.prioritizeFaceIDOnLockScreen)
            }
        }
    }

    /// 현재 macOS 세션이 잠금 화면(Lock Screen) 상태인지 실시간 확인
    public func isMacScreenLocked() -> Bool {
        if isScreenCurrentlyLocked {
            return true
        }
        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return false
    }

    /// 잠금 화면에서 Face ID 인증 성공 시 최우선으로 암호 입력창을 비우고 자격증명을 주입하여 즉시 잠금 해제
    private func submitUnlockCredentialIfScreenLockedAndIdle(prioritizeFaceID: Bool = true) {
        guard isMacScreenLocked() else { return }
        if !prioritizeFaceID {
            // 최우선 모드가 꺼져 있을 때만 수동 키보드 타이핑 중(2.0초 이내) 여부를 확인해 양보
            let secondsSinceKeyPress = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            guard secondsSinceKeyPress > 2.0 else { return }
        }
        guard let password = store.loadUnlockCredential(), !password.isEmpty else { return }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // 1순위 Face ID 최우선 모드: 화면을 깨우기 위해 누른 키나 입력 중이던 잔여 글자를 전체 선택(Cmd+A) 후 삭제(Delete)하여 충돌 방지
        if prioritizeFaceID {
            if let selectAllDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let selectAllUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
               let deleteDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
               let deleteUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                selectAllDown.flags = .maskCommand
                selectAllUp.flags = .maskCommand
                selectAllDown.post(tap: .cghidEventTap)
                selectAllUp.post(tap: .cghidEventTap)
                deleteDown.post(tap: .cghidEventTap)
                deleteUp.post(tap: .cghidEventTap)
            }
        }

        let utf16Chars = Array(password.utf16)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        // Return 키 전송 (virtualKey 36) -> 잠금 화면 즉시 해제
        if let retDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
           let retUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            retDown.post(tap: .cghidEventTap)
            retUp.post(tap: .cghidEventTap)
        }
        stopLockScreenPriorityMonitor()
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

