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

echo "🚀 [1/2] MacFaceID.app 응용 프로그램 및 로그인 자동 실행(LaunchAgent) 설치 중..."

rm -rf /Applications/MacFaceID.app
cp -R "$DIST_DIR/MacFaceID.app" /Applications/MacFaceID.app

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$LAUNCH_AGENTS_DIR/com.macfaceid.goldengate.app.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macfaceid.goldengate.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/MacFaceID.app/Contents/MacOS/MacFaceID</string>
        <string>--background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

echo "🚀 [2/2] 시스템 인증 모듈(faceid-cli, pam_faceid.so, FaceIDAuthPlugin.bundle) 설치 중 (관리자 권한 필요)..."

PRIVILEGED_SCRIPT="/tmp/macfaceid_priv_install.sh"
cat > "$PRIVILEGED_SCRIPT" <<EOF
#!/bin/zsh
set -e
mkdir -p /usr/local/bin
mkdir -p /usr/local/lib/pam
mkdir -p /Library/Security/SecurityAgentPlugins

cp "$DIST_DIR/bin/faceid-cli" /usr/local/bin/faceid-cli
cp "$DIST_DIR/bin/libFaceIDCore.dylib" /usr/local/bin/libFaceIDCore.dylib
chmod 755 /usr/local/bin/faceid-cli /usr/local/bin/libFaceIDCore.dylib

cp "$DIST_DIR/pam/pam_faceid.so" /usr/local/lib/pam/pam_faceid.so
chmod 755 /usr/local/lib/pam/pam_faceid.so

rm -rf /Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle
cp -R "$DIST_DIR/AuthPlugin/FaceIDAuthPlugin.bundle" /Library/Security/SecurityAgentPlugins/

if [ -f /etc/pam.d/sudo_local ]; then
    sed -i '' '/pam_faceid.so/d' /etc/pam.d/sudo_local
    cp /etc/pam.d/sudo_local /etc/pam.d/sudo_local.bak
    awk 'NR==1{print "auth       sufficient     /usr/local/lib/pam/pam_faceid.so"}1' /etc/pam.d/sudo_local.bak > /etc/pam.d/sudo_local
else
    cat > /etc/pam.d/sudo_local <<PAMEOF
# sudo_local: 1st Priority Face ID -> 2nd Touch ID -> 3rd Password
auth       sufficient     /usr/local/lib/pam/pam_faceid.so
auth       sufficient     pam_tid.so
PAMEOF
fi

if [ -f /etc/pam.d/screensaver ]; then
    sed -i '' '/pam_faceid.so/d' /etc/pam.d/screensaver 2>/dev/null || true
    cp /etc/pam.d/screensaver /etc/pam.d/screensaver.bak 2>/dev/null || true
    awk 'NR==1{print; print "auth       sufficient     /usr/local/lib/pam/pam_faceid.so"; next}1' /etc/pam.d/screensaver.bak > /etc/pam.d/screensaver 2>/dev/null || true
fi
EOF
chmod 755 "$PRIVILEGED_SCRIPT"

if [ "$EUID" -eq 0 ]; then
    "$PRIVILEGED_SCRIPT"
elif [ -t 0 ]; then
    sudo "$PRIVILEGED_SCRIPT"
else
    osascript -e "do shell script \"$PRIVILEGED_SCRIPT\" with administrator privileges"
fi
rm -f "$PRIVILEGED_SCRIPT"

echo "✅ MacFaceID 설치가 완료되었습니다! (/Applications/MacFaceID.app 및 시스템 인증 모듈 적용 완료)"

