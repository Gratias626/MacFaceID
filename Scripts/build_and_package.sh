#!/bin/zsh
# build_and_package.sh
# MacBook Air M2 (macOS Golden Gate) Face ID 통합 빌드 및 시스템 모듈 패키징 스크립트

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/dist"
export CLANG_MODULE_CACHE_PATH="/tmp/macfaceid_clang_cache"

mkdir -p "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$BUILD_DIR/pam"
mkdir -p "$BUILD_DIR/AuthPlugin/FaceIDAuthPlugin.bundle/Contents/MacOS"
mkdir -p "$BUILD_DIR/bin"

echo "🔨 [1/3] Swift 타겟(FaceIDCore, MacFaceIDApp, faceid-cli) 컴파일 중..."
cd "$PROJECT_ROOT"

swiftc -O \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -module-name FaceIDCore \
    -emit-library -emit-module \
    -emit-module-path "$BUILD_DIR/FaceIDCore.swiftmodule" \
    -o "$BUILD_DIR/libFaceIDCore.dylib" \
    Sources/FaceIDCore/*.swift \
    -framework AVFoundation -framework Vision -framework CoreML \
    -framework Security -framework CryptoKit -framework LocalAuthentication -framework AppKit

swiftc -O -parse-as-library \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lFaceIDCore \
    -Xlinker -rpath -Xlinker "$BUILD_DIR" \
    -Xlinker -rpath -Xlinker "@executable_path" \
    -o "$BUILD_DIR/bin/faceid-cli" \
    Sources/FaceIDCLI/main.swift

swiftc -O -parse-as-library \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lFaceIDCore \
    -Xlinker -rpath -Xlinker "$BUILD_DIR" \
    -Xlinker -rpath -Xlinker "@executable_path" \
    -o "$BUILD_DIR/bin/MacFaceID" \
    Sources/MacFaceIDApp/*.swift \
    -framework SwiftUI -framework AppKit -framework AVFoundation

cp "$BUILD_DIR/libFaceIDCore.dylib" "$BUILD_DIR/bin/libFaceIDCore.dylib"

# macOS .app 번들(MacFaceID.app) 생성 (카메라 권한 Info.plist 포함)
APP_BUNDLE="$BUILD_DIR/MacFaceID.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/bin/MacFaceID" "$APP_BUNDLE/Contents/MacOS/MacFaceID"
cp "$BUILD_DIR/libFaceIDCore.dylib" "$APP_BUNDLE/Contents/MacOS/libFaceIDCore.dylib"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacFaceID</string>
    <key>CFBundleIdentifier</key>
    <string>com.macfaceid.goldengate.app</string>
    <key>CFBundleName</key>
    <string>MacFaceID</string>
    <key>CFBundleDisplayName</key>
    <string>Face ID (MacBook Air M2)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSCameraUsageDescription</key>
    <string>Touch ID를 대체하여 Mac 잠금 해제 및 sudo 권한 승인을 위해 내장 FaceTime HD 카메라로 얼굴을 인식합니다.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

swiftc -O -parse-as-library \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lFaceIDCore \
    -Xlinker -rpath -Xlinker "$BUILD_DIR" \
    -Xlinker -rpath -Xlinker "@executable_path" \
    -o "$BUILD_DIR/bin/faceid-tests" \
    Tests/FaceIDCoreTests/TestRunner.swift

echo "🔨 [2/3] Custom PAM 모듈 (pam_faceid.so) 컴파일 중..."
clang -dynamiclib -O2 \
    "$PROJECT_ROOT/SystemModules/PAM/pam_faceid.c" \
    -o "$BUILD_DIR/pam/pam_faceid.so" \
    -lpam

echo "🔨 [3/3] macOS SecurityAgent Authorization Plugin (FaceIDAuthPlugin.bundle) 컴파일 중..."
clang -dynamiclib -O2 \
    "$PROJECT_ROOT/SystemModules/AuthPlugin/FaceIDAuthPlugin.c" \
    -o "$BUILD_DIR/AuthPlugin/FaceIDAuthPlugin.bundle/Contents/MacOS/FaceIDAuthPlugin" \
    -framework Security -framework CoreFoundation

cat > "$BUILD_DIR/AuthPlugin/FaceIDAuthPlugin.bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FaceIDAuthPlugin</string>
    <key>CFBundleIdentifier</key>
    <string>com.macfaceid.goldengate.authplugin</string>
    <key>CFBundleName</key>
    <string>FaceIDAuthPlugin</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
</dict>
</plist>
EOF

echo "✅ 빌드 및 패키징 완료! 산출물 위치: $BUILD_DIR"
ls -la "$BUILD_DIR/bin" "$BUILD_DIR/pam" "$BUILD_DIR/AuthPlugin/FaceIDAuthPlugin.bundle/Contents/MacOS"
