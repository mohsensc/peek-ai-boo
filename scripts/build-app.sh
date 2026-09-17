#!/bin/sh
# Builds the release binary and hand-assembles dist/PeekAiBoo.app. No Xcode
# here, so no xcodebuild — just a plist and codesign.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product PeekAiBoo

app=dist/PeekAiBoo.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

cp .build/release/PeekAiBoo "$app/Contents/MacOS/PeekAiBoo"

cat > "$app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.mohsensc.peekaiboo</string>
	<key>CFBundleExecutable</key>
	<string>PeekAiBoo</string>
	<key>CFBundleName</key>
	<string>PeekAiBoo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>peek-ai-boo focuses the terminal your agent runs in.</string>
</dict>
</plist>
EOF

if [ -d Resources ]; then
  mkdir -p "$app/Contents/Resources"
  cp -R Resources/. "$app/Contents/Resources/"
fi

make -C hook
mkdir -p "$app/Contents/Helpers"
cp hook/.build/peekaboo-hook "$app/Contents/Helpers/peekaboo-hook"
chmod +x "$app/Contents/Helpers/peekaboo-hook"
# Sign the helper before the app: signing the bundle first and dropping a
# file in after breaks its seal.
codesign --force --sign - "$app/Contents/Helpers/peekaboo-hook"

codesign --force --sign - "$app"
