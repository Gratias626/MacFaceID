import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

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
    private var lastLockScreenScanTime: CFAbsoluteTime = 0
    private var lockScreenPriorityTimer: Timer?
    private var backgroundActivity: NSObjectProtocol?
    public var onAuthStateChanged: ((AuthenticationState) -> Void)?

    public init(
        authController: FaceIDAuthenticationController = .shared,
        store: SecureEnclaveStore = .shared
    ) {
        self.authController = authController
        self.store = store
    }

    /// 시스템 슬립 깨우기(Wake from Sleep) 및 화면 잠금 이벤트 모니터링 시작 (평상시 CPU 0% Zero-Polling)
    public func startMonitoringSystemEvents() {
        stopMonitoringSystemEvents()

        let wsCenter = NSWorkspace.shared.notificationCenter

        // 1. 맥북 덮개를 열거나 슬립에서 깨어날 때 잠금 상태이면 즉시 1순위로 Face ID 스캔 트리거
        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isMacScreenLocked() else { return }
            self.wakeDisplayForLockScreen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.triggerParallelFaceIDUnlockIfNeeded()
            }
        }

        // 2. 디스플레이가 다시 켜질 때 잠금 상태이면 1순위 Face ID 트리거
        let screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isMacScreenLocked() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.triggerParallelFaceIDUnlockIfNeeded()
            }
        }

        workspaceObservers.append(contentsOf: [wakeObserver, screenWakeObserver])

        // 3. macOS 화면 잠금/해제 DistributedNotification 감지 (오직 잠금 중에만 타이머/액티비티 활성화 -> 평상시 리소스 0%)
        let distCenter = DistributedNotificationCenter.default()
        let lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isScreenCurrentlyLocked = true
            self.onAuthStateChanged?(.scanning)
            self.startLockScreenPriorityMonitor()
            // 잠금 화면 진입 직후(0.65초 후 로그인 입력창이 준비된 즉시) 자동으로 1순위 Face ID 스캔 시작
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self = self, self.isMacScreenLocked() else { return }
                self.triggerParallelFaceIDUnlockIfNeeded()
            }
        }

        // 잠금 해제 완료 즉시 모든 타이머 및 백그라운드 액티비티 해제 -> 평상시 CPU 0.0% 복귀
        let unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isScreenCurrentlyLocked = false
            self.stopLockScreenPriorityMonitor()
            CameraCaptureService.shared.stopCapture()
            self.authController.resetSecurityPolicyAfterPasswordUnlock()
            self.onAuthStateChanged?(.idle)
        }
        distributedObservers.append(contentsOf: [lockObserver, unlockObserver])

        // 4. 부재 시 자동 화면 잠금 옵션이 켜져 있을 때만 타이머 등록
        updateWalkAwayAutoLockTimer()
    }

    /// 실제 물리 입력(키보드/트랙패드/마우스/스크롤) 이후 경과 시간(초) 반환
    public func secondsSinceLastUserInput() -> Double {
        let inputTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel
        ]
        return inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 9999.0
    }

    /// 오직 화면이 잠겨 있는 동안에만 활성화되는 경량 깨우기 감지기 (잠금 해제 시 즉시 메모리/타이머 반환)
    private func startLockScreenPriorityMonitor() {
        stopLockScreenPriorityMonitor()
        let config = store.loadConfiguration()
        guard config.isEnabledForScreenUnlock else { return }

        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "MacFaceID Active Lock Screen Session"
        )

        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isMacScreenLocked() else {
                self.stopLockScreenPriorityMonitor()
                return
            }
            guard !self.isScanningLockScreen else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // 스캔 쿨다운(2.8초)을 적용하여 불필요한 연속 카메라 가동 방지
            guard now - self.lastLockScreenScanTime >= 2.8 else { return }

            if self.secondsSinceLastUserInput() < 1.2 {
                self.triggerParallelFaceIDUnlockIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockScreenPriorityTimer = timer
    }

    private func stopLockScreenPriorityMonitor() {
        lockScreenPriorityTimer?.invalidate()
        lockScreenPriorityTimer = nil
        if let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
        }
    }

    private func wakeDisplayForLockScreen() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-u", "-t", "3"]
        try? proc.run()
    }

    /// 잠금 화면에서 Touch ID 및 비밀번호 입력보다 Face ID를 1순위로 선제 수행하고, 미인식 시에만 Touch ID/비밀번호로 폴백
    private func triggerParallelFaceIDUnlockIfNeeded() {
        let config = store.loadConfiguration()
        guard config.isEnabledForScreenUnlock, !isScanningLockScreen else { return }
        isScanningLockScreen = true
        lastLockScreenScanTime = CFAbsoluteTimeGetCurrent()

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
        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
                return locked
            }
            if let lockedNum = sessionDict["CGSSessionScreenIsLocked"] as? NSNumber {
                return lockedNum.boolValue
            }
        }
        return isScreenCurrentlyLocked
    }

    /// 잠금 화면에서 Face ID 인증 성공 시 최우선으로 암호 입력창을 비우고 자격증명을 1글자씩 정확히 주입하여 즉시 잠금 해제
    public func submitUnlockCredentialIfScreenLockedAndIdle(prioritizeFaceID: Bool = true) {
        guard isMacScreenLocked() else { return }
        if !prioritizeFaceID {
            let secondsSinceKeyPress = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            guard secondsSinceKeyPress > 2.0 else { return }
        }
        guard let password = store.loadUnlockCredential(), !password.isEmpty else { return }

        wakeDisplayForLockScreen()
        usleep(80_000)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // 1) 화면을 깨우기 위해 누른 키나 입력 중이던 잔여 글자를 전체 선택(Cmd+A) 후 삭제(Backspace)하여 충돌 방지
        if prioritizeFaceID {
            if let selectAllDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let selectAllUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
               let deleteDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
               let deleteUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                selectAllDown.flags = .maskCommand
                selectAllUp.flags = .maskCommand
                selectAllDown.post(tap: .cghidEventTap)
                selectAllUp.post(tap: .cghidEventTap)
                usleep(10_000)
                deleteDown.post(tap: .cghidEventTap)
                deleteUp.post(tap: .cghidEventTap)
                usleep(20_000)
            }
        }

        // 2) macOS loginwindow NSSecureTextField 호환을 위해 UTF-16 1글자씩 순차 전송
        for utf16Unit in password.utf16 {
            var char = utf16Unit
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyDown.flags = []
                keyUp.flags = []
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                usleep(5_000)
            }
        }

        usleep(25_000)
        // 3) Return 키 전송 (virtualKey 36) -> 잠금 화면 즉시 해제
        if let retDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
           let retUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
            retDown.flags = []
            retUp.flags = []
            retDown.post(tap: .cghidEventTap)
            retUp.post(tap: .cghidEventTap)
        }
    }

    private var walkAwayTimer: Timer?

    /// 자리 비움 자동 잠금 옵션이 켜져 있을 때만 타이머를 등록하고, 꺼져 있으면 타이머를 완전히 제거(Zero-Polling)
    public func updateWalkAwayAutoLockTimer() {
        walkAwayTimer?.invalidate()
        walkAwayTimer = nil
        let config = store.loadConfiguration()
        guard config.autoLockOnWalkAway else { return }

        walkAwayTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentConfig = self.store.loadConfiguration()
            guard currentConfig.autoLockOnWalkAway, !self.isMacScreenLocked() else { return }

            Task {
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
        stopLockScreenPriorityMonitor()
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

