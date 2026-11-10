# MacFaceID (for MacBook Air M2 · macOS Golden Gate)

MacBook Air M2의 내장 1080p FaceTime HD 카메라와 Apple M2 Neural Engine(`Vision` + `CoreML`)을 활용하여, 지문 인식(Touch ID) 기능을 iPhone 스타일의 **Face ID**로 대체/보완하는 온디바이스 생체 인증 솔루션입니다.

## 주요 기능

1. **Touch ID = Face ID 시스템 인증 통합**
   - **Mac 잠금 해제**: `SecurityAgent` 기반 Authorization Plugin (`FaceIDAuthPlugin.bundle`) 및 `NSWorkspace` 슬립 깨우기 감지 연동
   - **터미널 `sudo` 권한 승격**: Custom PAM 모듈 (`pam_faceid.so`)을 통해 `pam_tid.so`(Touch ID)와 동일한 즉시 인증 제공
2. **iPhone Face ID 스타일 UI/UX**
   - **원형 3D 다각도 스캔 마법사**: 정면·좌·우·상·하 5방향 얼굴 특징 벡터 등록 및 보조 외모(Alternate Appearance) 지원
   - **Dynamic Notch HUD**: MacBook Air M2 상단 노치 하단에 플로팅 캡슐 애니메이션 및 저조도 화면 보조 조명(Face Illumination) 표시
3. **강력한 온디바이스 보안 및 Anti-Spoofing**
   - **Liveness & Attention Detection**: 양안 개안 비율(EAR), 동공 시선 주시 확인, 표면 질감 분석으로 2D 사진/화면 재생 위변조 차단
   - **Secure Enclave & AES-GCM 256-bit**: 원본 얼굴 이미지는 절대 저장하지 않으며, 128차원 정규화 임베딩 벡터만 암호화 보관
   - **iPhone Face ID 보안 정책 준수**: 연속 5회 실패, 재부팅 직후 최초 로그인, 48시간 경과 시 즉시 Touch ID/암호 입력으로 Fallback 전환

## 프로젝트 구조

- `Sources/FaceIDCore/`: 128D 얼굴 임베딩 엔진, Liveness 위변조 판별, 카메라 캡처, AES-GCM 보안 저장소
- `Sources/MacFaceIDApp/`: SwiftUI 환경설정 앱, 원형 스캔 마법사, 노치 Dynamic HUD 오버레이
- `Sources/FaceIDCLI/`: 고속 CLI 인증 도구 (`faceid-cli`)
- `SystemModules/PAM/`: 터미널 `sudo` 연동 C PAM 모듈 (`pam_faceid.c`)
- `SystemModules/AuthPlugin/`: macOS 잠금화면 연동 C SecurityAgent 플러그인 (`FaceIDAuthPlugin.c`)
- `Tests/FaceIDCoreTests/`: 단위 테스트 및 보안 정책 자동화 검증 스위트
- `Scripts/`: 통합 빌드(`build_and_package.sh`), 설치(`install.sh`), 제거(`uninstall.sh`) 스크립트

## 빌드 및 실행 방법

```zsh
# 1. 전체 타겟 빌드 및 패키징 (dist/ 생성)
./Scripts/build_and_package.sh

# 2. 단위 테스트 실행
./dist/bin/faceid-tests

# 3. GUI 앱 실행
open ./dist/MacFaceID.app

# 4. CLI 상태 확인 및 인증 테스트
./dist/bin/faceid-cli status
./dist/bin/faceid-cli verify
```
