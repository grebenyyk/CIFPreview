#!/bin/bash
# cif-ql build: generate project → xcodebuild → sign → register
#   ./build.sh            build into ./build/CIFPreview.app
#   ./build.sh install    also install to ~/Applications and register there
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CIFPreview.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild (Release)"
xcodebuild -project "$ROOT/CIFPreview.xcodeproj" \
    -scheme CIFPreview -configuration Release \
    -derivedDataPath "$ROOT/.build/xcode" \
    build CODE_SIGNING_ALLOWED=NO \
    > /tmp/cifql_xcodebuild.log 2>&1 || { tail -40 /tmp/cifql_xcodebuild.log; exit 1; }
echo "    build ok"

echo "==> assemble"
rm -rf "$ROOT/build"
mkdir -p "$ROOT/build"
cp -R "$ROOT/.build/xcode/Build/Products/Release/CIFPreview.app" "$APP"

echo "==> codesign (inside-out, ad-hoc)"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/appex.entitlements" \
    "$APP/Contents/PlugIns/CIFQuickLook.appex"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "    signatures ok"

if [ "${1:-}" = "install" ]; then
    DEST="$HOME/Applications/CIFPreview.app"
    echo "==> install to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    "$LSREG" -f "$DEST"
    # launching the host app once is what makes pluginkit discover the appex
    open -g "$DEST"
else
    "$LSREG" -f "$APP"
    open -g "$APP"
fi
sleep 2

echo "==> registered preview extensions:"
pluginkit -m -p com.apple.quicklook.preview | grep -i cifpreview || echo "  (cifpreview extension not yet visible)"
echo "==> done: $APP"
