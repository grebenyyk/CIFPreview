#!/bin/bash
# Re-register the extension after a macOS update (updates can wipe the
# pluginkit/LaunchServices record for ad-hoc signed apps). Also handy if the
# preview stops working for no obvious reason.
set -euo pipefail
DEST="$HOME/Applications/CIFPreview.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -d "$DEST" ] || { echo "not installed — run ./build.sh install first"; exit 1; }
"$LSREG" -f "$DEST"
open -g "$DEST"          # launching the host app once is what pluginkit needs
sleep 2
killall quicklookd 2>/dev/null || true
pluginkit -m -p com.apple.quicklook.preview | grep -i cifpreview \
    && echo "re-registered ✓" || echo "still missing — try a logout/login"
