#!/bin/zsh
# swift build → Recper.app (Info.plist, ad-hoc signature). Command Line Tools or Xcode is enough.
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release --product Recper
APP=build/Recper.app
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources}
# The product directory depends on the toolchain (CLT: .build/release, Xcode: .build/out/Products/Release).
cp "$(swift build -c release --show-bin-path)/Recper" $APP/Contents/MacOS/Recper
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Recper</string>
  <key>CFBundleIdentifier</key><string>dev.halid.recper</string>
  <key>CFBundleExecutable</key><string>Recper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>recper transcribes your speech on-device; audio is never recorded or uploaded.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Speech is transcribed on this Mac and never sent anywhere.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>dev.halid.recper</string>
    <key>CFBundleURLSchemes</key><array><string>recper</string></array>
  </dict></array>
</dict></plist>
PLIST
strip -x $APP/Contents/MacOS/Recper
# If a stable identity exists (scripts/dev-cert.sh), sign with it so TCC permissions survive rebuilds.
if security find-identity -v -p codesigning | grep -q recper-dev; then
  codesign --force --sign recper-dev $APP
else
  # With ad-hoc signing, TCC grants are tied to the cdhash and lost on every build. Binding the requirement to the
  # identifier alone keeps them across builds (local development only; distribution needs a real signature).
  codesign --force --sign - -r='designated => identifier "dev.halid.recper"' $APP
fi
echo "$APP $(du -sk $APP | cut -f1) KB"
