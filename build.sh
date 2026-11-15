#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
requested_identity="${SIGN_IDENTITY:-}"
if [[ -f .local-signing.env ]]; then source .local-signing.env; fi
if [[ -n "$requested_identity" ]]; then SIGN_IDENTITY="$requested_identity"; fi
APP="${APP_OUTPUT:-$PWD/build/轻截.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PWD/Artwork/LightCaptureIcon.icns" "$APP/Contents/Resources/LightCaptureIcon.icns"
mkdir -p "$APP/Contents/Resources/AuthorLinks"
cp "$PWD/Artwork/AuthorLinks/"* "$APP/Contents/Resources/AuthorLinks/"
mkdir -p "$APP/Contents/Resources/SupportQR"
cp "$PWD/Artwork/SupportQR/"* "$APP/Contents/Resources/SupportQR/"
cp -R "$PWD/Resources/"*.lproj "$APP/Contents/Resources/"
xcrun swiftc -module-cache-path "$PWD/build/ModuleCache" -swift-version 5 -O -target arm64-apple-macosx15.0 Sources/*.swift -o "$APP/Contents/MacOS/LightCapture" -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.jerry.lightcapture</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleName</key><string>轻截</string>
<key>CFBundleDisplayName</key><string>轻截</string>
<key>CFBundleIconFile</key><string>LightCaptureIcon.icns</string>
<key>CFBundleExecutable</key><string>LightCapture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>仅在你开启麦克风选项并开始录屏时录制麦克风声音。</string>
<key>NSScreenCaptureUsageDescription</key><string>仅在你主动截图或录屏时读取所选屏幕内容。</string>
</dict></plist>
PLIST
if [[ -n "${BUNDLE_ID:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"; fi
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
