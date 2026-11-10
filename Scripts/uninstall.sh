#!/bin/zsh
# uninstall.sh
# MacFaceID 완전 제거 스크립트 (실행 프로세스, 앱, 시스템 모듈, 암호화 저장소, 키체인, 캐시 및 설정값 100% 초기화)

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "🛑 [1/4] 실행 중인 MacFaceID 프로세스 및 LaunchAgent 종료 중..."
launchctl unload "$HOME/Library/LaunchAgents/com.macfaceid.goldengate.app.plist" 2>/dev/null || true
killall -9 MacFaceID faceid-cli 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.macfaceid.goldengate.app.plist"

echo "🗑️ [2/4] 응용 프로그램(/Applications/MacFaceID.app) 및 빌드 산출물 삭제 중..."
if [ -x "$LSREGISTER" ] && [ -d "/Applications/MacFaceID.app" ]; then
    "$LSREGISTER" -u "/Applications/MacFaceID.app" 2>/dev/null || true
fi
rm -rf /Applications/MacFaceID.app
rm -rf "$PROJECT_ROOT/dist"
rm -rf /tmp/macfaceid_clang_cache /tmp/macfaceid*

echo "🧹 [3/4] 모든 설정값, 얼굴 데이터(~/.macfaceid), 키체인 마스터 키 및 macOS 캐시/TCC 초기화 중..."
security delete-generic-password -s "com.macfaceid.goldengate.securestore" -a "faceid_master_key_v1" 2>/dev/null || true
rm -rf "$HOME/.macfaceid"
rm -rf "$PROJECT_ROOT/.macfaceid_store"
defaults delete com.macfaceid.goldengate.app 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/com.macfaceid.goldengate.app.plist"
rm -rf "$HOME/Library/Caches/com.macfaceid.goldengate.app"
rm -rf "$HOME/Library/Saved Application State/com.macfaceid.goldengate.app.savedState"
rm -rf "$HOME/Library/Application Support/MacFaceID"
tccutil reset All com.macfaceid.goldengate.app 2>/dev/null || true

echo "🔐 [4/4] 시스템 인증 모듈(PAM, SecurityAgentPlugin, CLI) 제거 중 (관리자 권한 필요)..."
PRIV_UNINSTALL="/tmp/macfaceid_priv_uninstall.sh"
cat > "$PRIV_UNINSTALL" <<'EOF'
#!/bin/zsh
if [ -f /etc/pam.d/sudo_local ]; then
    sed -i '' '/pam_faceid.so/d' /etc/pam.d/sudo_local 2>/dev/null || true
    rm -f /etc/pam.d/sudo_local.bak
fi

if [ -f /etc/pam.d/screensaver ]; then
    sed -i '' '/pam_faceid.so/d' /etc/pam.d/screensaver 2>/dev/null || true
    rm -f /etc/pam.d/screensaver.bak 2>/dev/null || true
fi

rm -f /usr/local/lib/pam/pam_faceid.so
rm -f /usr/local/bin/faceid-cli /usr/local/bin/libFaceIDCore.dylib
rm -rf /Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle
EOF
chmod 755 "$PRIV_UNINSTALL"

if [ "$EUID" -eq 0 ]; then
    "$PRIV_UNINSTALL"
elif [ -t 0 ]; then
    sudo "$PRIV_UNINSTALL"
else
    osascript -e "do shell script \"$PRIV_UNINSTALL\" with administrator privileges"
fi
rm -f "$PRIV_UNINSTALL"

echo "✅ MacFaceID 관련 모든 프로세스, 앱, 시스템 모듈 및 설정 데이터가 찌꺼기 없이 100% 삭제되었습니다."

