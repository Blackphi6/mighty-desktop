#!/usr/bin/env bash
# gui/ の Swift ソースをビルドし、/Applications/mighty.app に配置・署名する。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/mighty.app"

swiftc -parse-as-library -O -o "$DIR/mighty" \
  "$DIR/Models.swift" "$DIR/BackendManager.swift" "$DIR/ConversationStore.swift" \
  "$DIR/ChatViewModel.swift" "$DIR/ChatView.swift" "$DIR/RootView.swift" "$DIR/MightyApp.swift" \
  -framework SwiftUI -framework AppKit

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/mighty" "$APP/Contents/MacOS/mighty"
chmod +x "$APP/Contents/MacOS/mighty"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/mighty.icns" "$APP/Contents/Resources/mighty.icns"
cp "$DIR/Resources/mark.png" "$APP/Contents/Resources/mark.png"
codesign --force --deep --sign - "$APP"
echo "deployed: $(stat -f '%Sm' "$APP/Contents/MacOS/mighty")"
