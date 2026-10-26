#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="Atoll.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SDK="$(xcrun --show-sdk-path)"
swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework ApplicationServices \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework Accelerate \
  -o "$APP/Contents/MacOS/Atoll" \
  Sources/IslandApp.swift \
  Sources/NowPlayingService.swift \
  Sources/IslandView.swift \
  Sources/Snapshot.swift \
  Sources/MediaRemoteBridge.swift \
  Sources/AudioSpectrum.swift \
  Sources/DemoRecorder.swift \
  Sources/ExternalIsland.swift

mkdir -p "$APP/Contents/Resources"
clang -dynamiclib -fobjc-arc -framework Foundation -arch arm64 -mmacosx-version-min=14.0 \
  -o "$APP/Contents/Resources/adapter.dylib" Helper/adapter.m
cp Helper/run.pl "$APP/Contents/Resources/run.pl"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Atoll.icns ] && cp Resources/Atoll.icns "$APP/Contents/Resources/Atoll.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Стабильная подпись нужна, чтобы macOS не сбрасывал разрешения при пересборке.
# Порядок: SIGN_IDENTITY из окружения, затем первый найденный Apple Development, иначе ad-hoc ("-").
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "сертификат подписи не найден, подписываю ad-hoc"
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier local.island.notch "$APP" >/dev/null
echo "built $(pwd)/$APP"
