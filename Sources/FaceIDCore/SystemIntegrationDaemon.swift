import Foundation
import AppKit

/// macOS Golden Gate 시스템 이벤트(화면 잠금, 슬립 깨우기, 자리 비움 감지) 연동 데몬 매니저
/// Touch ID와 동일하게 화면이 켜지거나 잠금 해제 요청이 발생할 때 즉시 Face ID 인증을 수행합니다.
public final class SystemIntegrationDaemon: @unchecked Sendable {
    public static let shared = SystemIntegrationDaemon()

    private let authController: FaceIDAuthenticationController
    private let store: SecureEnclaveStore
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
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

        // 1. 맥북 덮개를 열거나 슬립에서 깨어날 때 즉시 Face ID 스캔 트리거
        let wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let config = self.store.loadConfiguration()
            guard config.isEnabledForScreenUnlock else { return }
            Task {
                self.onAuthStateChanged?(.scanning)
                let result = await self.authController.authenticateWithCamera()
                self.onAuthStateChanged?(result)
            }
        }

        // 2. 디스플레이가 다시 켜질 때 트리거
        let screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let config = self.store.loadConfiguration()
            guard config.isEnabledForScreenUnlock else { return }
            Task {
                self.onAuthStateChanged?(.scanning)
                let result = await self.authController.authenticateWithCamera()
                self.onAuthStateChanged?(result)
            }
        }

        workspaceObservers.append(contentsOf: [wakeObserver, screenWakeObserver])

        // 3. macOS 화면 잠금/해제 DistributedNotification 감지
        let distCenter = DistributedNotificationCenter.default()
        let lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAuthStateChanged?(.idle)
        }
        distributedObservers.append(lockObserver)

        // 4. 부재 시 자동 화면 잠금 (Auto-Lock on Walk Away) 타이머 모니터링
        startWalkAwayAutoLockTimerIfNeeded()
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

