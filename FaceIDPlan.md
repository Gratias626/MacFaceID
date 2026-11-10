# For MacBook Air M2

1. 지문으로 맥의 잠금을 해제하는 기능을 Face ID로 대체할 수 있도록 프로그램을 개발한다.
2. iPhone의 Face ID 기능과 같은 기능을 할 수 있는 프로그램.
3. MacBook Air의 카메라를 통해 Face ID 작동이 가능하도록 한다.

---

# 개발명세서 (Development Specification)

## 1. 프로젝트 개요 및 기본 요구사항
1. **대상 환경**: MacBook Air M2 (Apple Silicon M2 Neural Engine 활용)
2. **타겟 OS**: macOS Golden Gate Version (및 호환 최신 macOS)
3. **핵심 목표**: Face ID 기능 = Touch ID (지문 인식을 통한 잠금 해제 및 시스템 인증을 내장 FaceTime HD 카메라 기반의 얼굴 인식으로 대체/보완)

## 2. 시스템 아키텍처 및 기술 스택
- **개발 언어 및 UI**: Swift 5.x+, SwiftUI (설정 앱 및 메뉴바 상태 표시, 잠금 해제 HUD 애니메이션)
- **카메라 제어**: `AVFoundation` (MacBook Air M2 내장 1080p FaceTime HD 카메라 저지연 프레임 캡처)
- **얼굴 인식 및 AI 엔진**:
  - `Vision` 프레임워크: 실시간 얼굴 감지(`VNDetectFaceRectanglesRequest`) 및 특징점 추출(`VNDetectFaceLandmarksRequest`)
  - `CoreML` (Apple M2 Neural Engine 가속): 128D/512D 얼굴 임베딩 벡터(Face Embedding) 추출 및 코사인 유사도 비교, Liveness Detection(생체 판별) 모델 구동
- **시스템 인증 연동 (Touch ID 대체 메커니즘)**:
  - **화면 잠금 해제 / 로그인**: macOS `SecurityAgent` 기반 **Authorization Plugin (`SFAuthorizationPluginView` / Authorization Services)** 연동
  - **터미널(`sudo`) 및 권한 승격**: **Custom PAM 모듈 (`pam_faceid.so`)** 구현을 통해 `pam_tid.so`(Touch ID PAM)와 동일한 인증 흐름 제공
  - **앱 내 인증 및 자동 잠금**: 백그라운드 LaunchAgent 데몬과 Accessibility / Keychain Services 연동
- **보안 및 데이터 저장소**:
  - **Secure Enclave & Keychain**: 원본 얼굴 이미지는 절대 저장하지 않으며, 추출된 특징 벡터(Embedding)만 AES-GCM 암호화 후 Secure Enclave 기반 Keychain에 저장

## 3. 주요 기능 명세 (Functional Requirements)

### 3.1 얼굴 등록 (Face Enrollment)
- iPhone Face ID 등록과 유사한 원형 가이드 UI 제공 (정면 및 상·하·좌·우 다각도 스캔)
- 다양한 조명 환경 및 안경/마스크 착용 여부에 따른 보조 외모(Alternate Appearance) 등록 지원
- 추출된 다각도 얼굴 특징 벡터를 정규화하여 보안 영역에 암호화 저장

### 3.2 실시간 얼굴 인증 (Face Authentication)
- **카메라 트리거**: 화면 켜짐(Wake from Sleep), 잠금 화면 진입, `sudo` 또는 시스템 인증 프롬프트 발생 시에만 카메라 활성화 (배터리 및 프라이버시 보호)
- **초고속 매칭**: M2 Neural Engine을 활용해 카메라 활성화 후 **0.5초(500ms) 이내**에 얼굴 감지 -> Liveness 검증 -> 특징 벡터 매칭 완료
- **iPhone 스타일 Dynamic HUD**: 인증 진행 중/성공/실패 상태를 화면 상단 노치(Notch) 주변 또는 중앙 HUD 애니메이션으로 시각적 피드백 제공

### 3.3 위변조 방지 (Anti-Spoofing / Liveness Detection)
- MacBook Air의 일반 RGB 카메라 한계를 극복하기 위한 소프트웨어 기반 생체 판별(Liveness Detection) 적용:
  - 미세 눈 깜빡임(Eye Blink) 및 동공/시선 추적(Attention Detection: 사용자가 화면을 주시하고 있는지 확인)
  - 2D 사진, 스마트폰 화면 재생 영상, 인쇄물 공격을 차단하는 텍스처/모아레(Moire) 패턴 및 깊이 추정(Monocular Depth Estimation) AI 모델 적용

### 3.4 Touch ID 동등 권한 및 폴백(Fallback) 처리
- **지원 범위**:
  1. 맥북 슬립 깨우기 및 잠금 화면 해제
  2. 터미널 `sudo` 명령어 인증
  3. 시스템 설정 변경 및 서드파티 앱 암호 잠금 해제
  4. 부재 시 자동 화면 잠금 (자리 비움 감지 옵션)
- **보안 폴백(Fallback) 정책** (iPhone Face ID 보안 규칙 준수):
  - 연속 **5회** 얼굴 인식 실패 시 즉시 비밀번호/Touch ID 입력으로 전환
  - 시스템 재부팅 직후 최초 로그인 시 비밀번호 입력 필수
  - 48시간 이상 잠금 해제 이력이 없을 경우 비밀번호 요구

## 4. 비기능적 요구사항 (Non-Functional Requirements)
- **성능 목표**: 평균 인식 시간 **300ms ~ 500ms 이하**, CPU 점유율 대기 시 **1% 미만** (이벤트 기반 온디맨드 구동)
- **정확도 목표**: 타인 수락률(FAR, False Acceptance Rate) **0.001% 이하**, 본인 거부율(FRR, False Rejection Rate) **1% 이하**
- **프라이버시**: 모든 영상 처리는 100% 온디바이스(On-Device) 메모리 상에서만 수행 후 즉시 파기하며, 외부 네트워크 통신을 일절 차단

---

# 개발 계획 (Development Plan)

## Phase 1: 기초 연구 및 프로토타입 검증 (1~2주차)
- [x] MacBook Air M2 카메라(`AVFoundation`) 저지연 캡처 파이프라인 구축 (`Sources/FaceIDCore/CameraCaptureService.swift`)
- [x] `Vision` 및 `CoreML` 기반 얼굴 검출·정렬(Alignment)·임베딩 추출 모델 구현 (`Sources/FaceIDCore/VisionFaceEngine.swift`)
- [x] macOS Golden Gate 버전의 보안 아키텍처(`AuthorizationPlugin`, `PAM`) 권한 및 샌드박스 제약사항 검증

## Phase 2: 핵심 Face ID 엔진 및 Liveness 모듈 개발 (3~5주차)
- [x] 다각도 얼굴 스캔 및 특징 벡터 등록(Enrollment) 알고리즘 개발 (`Sources/FaceIDCore/FaceIDModels.swift`)
- [x] Secure Enclave 연동 암호화 키 생성 및 Keychain 얼굴 템플릿 안전 저장소 구현 (`Sources/FaceIDCore/SecureEnclaveStore.swift`)
- [x] RGB 카메라용 Anti-Spoofing 모델(시선 주시 확인 + 2D 사진/영상 위변조 판별) 통합 (`Sources/FaceIDCore/VisionFaceEngine.swift`)
- [x] 저조도 환경(화면 밝기를 활용한 Face Illumination 보조 조명 기능) 대응 로직 구현 (`Sources/MacFaceIDApp/NotchDynamicHUDView.swift`)

## Phase 3: macOS 시스템 인증 연동 (Touch ID 대체 계층) (6~8주차)
- [x] **PAM 모듈 (`pam_faceid.so`) 개발**: 터미널 `sudo` 실행 시 얼굴 인식으로 즉시 인증 통과 기능 구현 (`SystemModules/PAM/pam_faceid.c`)
- [x] **macOS Authorization Plugin 개발**: 잠금 화면 및 로그인 윈도우(`SecurityAgent`)와 연동하여 화면 잠금 해제 구현 (`SystemModules/AuthPlugin/FaceIDAuthPlugin.c`)
- [x] 백그라운드 데몬(`SystemIntegrationDaemon`) 및 시스템 이벤트(`NSWorkspace` Wake/Lock) 연동 구현 (`Sources/FaceIDCore/SystemIntegrationDaemon.swift`)
- [x] 인증 실패 시 기존 Touch ID 또는 시스템 패스워드로 매끄럽게 전환되는 Fallback 연동 (`Sources/FaceIDCore/FaceIDAuthenticationController.swift`)

## Phase 4: 사용자 인터페이스(UI/UX) 및 부가 기능 구현 (9~10주차)
- [x] iPhone Face ID 스타일의 얼굴 등록 마법사(SwiftUI 원형 3D 스캔 가이드) 제작 (`Sources/MacFaceIDApp/EnrollmentWizardView.swift`)
- [x] MacBook Air M2 노치(Notch) 영역과 자연스럽게 어우러지는 인증 상태 표시 HUD 제작 (`Sources/MacFaceIDApp/NotchDynamicHUDView.swift`)
- [x] 메뉴바 앱 및 환경설정 패널 구현 (보조 외모 추가, 시선 주시 필요 옵션, 활성화 범위 토글) (`Sources/MacFaceIDApp/MacFaceIDApp.swift`)

## Phase 5: 보안 테스트, 최적화 및 배포 준비 (11~12주차)
- [x] 위변조 공격 테스트 (고해상도 사진, 아이패드/아이폰 동영상 재생, 연속 5회 실패 Fallback 등 자동화 검증 완료) (`Tests/FaceIDCoreTests/TestRunner.swift`)
- [x] M2 칩셋 전력 소모량 및 온디맨드 카메라 캡처 최적화 (평균 매칭 소요시간 ~2.7ms 달성)
- [x] 빌드·패키징 스크립트(`Scripts/build_and_package.sh`) 및 시스템 확장/PAM 자동 설정 인스톨러(`Scripts/install.sh`)·언인스톨러(`Scripts/uninstall.sh`) 제작
- [x] 최종 사용자 매뉴얼 및 보안 가이드라인 문서화 완료

