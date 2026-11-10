#!/bin/zsh
# uninstall.sh
# MacFaceID 시스템 제거 및 복구 스크립트

set -e

echo "🗑️ MacFaceID 시스템 모듈을 제거합니다..."

if [ -f /etc/pam.d/sudo_local ]; then
    sudo sed -i '' '/pam_faceid.so/d' /etc/pam.d/sudo_local
fi

if [ -f /etc/pam.d/screensaver ]; then
    sudo sed -i '' '/pam_faceid.so/d' /etc/pam.d/screensaver
fi

sudo rm -f /usr/local/lib/pam/pam_faceid.so
sudo rm -f /usr/local/bin/faceid-cli
sudo rm -rf /Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle

echo "✅ MacFaceID 시스템 모듈이 안전하게 제거되었습니다."

