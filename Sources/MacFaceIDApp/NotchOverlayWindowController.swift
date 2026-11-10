import AppKit
import SwiftUI
import FaceIDCore

/// MacBook Air M2의 실제 화면 상단 노치(Notch) 바로 아래에 떠서 동작하는 비간섭(Non-Activating) 플로팅 HUD 윈도우 컨트롤러
/// 잠금 해제, 화면 깨우기, 터미널 sudo 인증 시 iPhone Dynamic Island / Face ID와 동일한 화면 최상단 애니메이션을 제공합니다.
@MainActor
public final class NotchOverlayWindowController {
    public static let shared = NotchOverlayWindowController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    /// 화면 최상단 노치 아래에 Face ID HUD 오버레이 표시
    public func showHUD(state: AuthenticationState, lowLightAssist: Bool = false, autoDismissAfter: TimeInterval? = 2.2) {
        dismissWorkItem?.cancel()

        let hudView = NotchDynamicHUDView(authState: state, lowLightAssistActive: lowLightAssist)
        let hostingView = NSHostingView(rootView: hudView)
        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 80
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.level = .statusBar
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newPanel.ignoresMouseEvents = true
            self.panel = newPanel
        }

        guard let panel = self.panel else { return }
        panel.contentView = hostingView

        // MacBook Air M2 메인 디스플레이 상단 중앙(노치 바로 아래) 좌표 계산
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let xPos = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2.0
            let yPos = visibleFrame.maxY - windowHeight - 6.0
            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1.0
        }

        if let delay = autoDismissAfter {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.hideHUD()
                }
            }
            dismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// 노치 HUD 숨기기
    public func hideHUD() {
        guard let panel = self.panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }
}

