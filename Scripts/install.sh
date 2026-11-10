#!/bin/zsh
# install.sh
# MacFaceID 시스템 설치 스크립트 (PAM sudo 연동 + SecurityAgent Authorization Plugin 설치)

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

if [ ! -f "$DIST_DIR/bin/faceid-cli" ]; then
    echo "📦 빌드 산출물이 없어 먼저 빌드를 수행합니다..."
    "$PROJECT_ROOT/Scripts/build_and_package.sh"
fi

echo "🚀 MacFaceID 시스템 설치를 시작합니다 (관리자 권한 필요)..."

sudo mkdir -p /usr/local/bin
sudo mkdir -p /usr/local/lib/pam
sudo mkdir -p /Library/Security/SecurityAgentPlugins

sudo cp "$DIST_DIR/bin/faceid-cli" /usr/local/bin/faceid-cli
sudo chmod 755 /usr/local/bin/faceid-cli

sudo cp "$DIST_DIR/pam/pam_faceid.so" /usr/local/lib/pam/pam_faceid.so
sudo chmod 755 /usr/local/lib/pam/pam_faceid.so

sudo cp -R "$DIST_DIR/AuthPlugin/FaceIDAuthPlugin.bundle" /Library/Security/SecurityAgentPlugins/

if [ -f /etc/pam.d/sudo_local ]; then
    if ! grep -q "pam_faceid.so" /etc/pam.d/sudo_local; then
        echo "auth       sufficient     /usr/local/lib/pam/pam_faceid.so" | sudo tee -a /etc/pam.d/sudo_local > /dev/null
    fi
else
    echo "# sudo_local: local customizations for sudo (Face ID = Touch ID)" | sudo tee /etc/pam.d/sudo_local > /dev/null
    echo "auth       sufficient     /usr/local/lib/pam/pam_faceid.so" | sudo tee -a /etc/pam.d/sudo_local > /dev/null
fi

echo "✅ MacFaceID 설치가 완료되었습니다! 이제 터미널 sudo 및 잠금 해제 시 Face ID가 작동합니다."

