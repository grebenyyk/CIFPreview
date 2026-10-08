#!/bin/bash
# cif-ql uninstall: unregister the extension, remove the app
set -euo pipefail
DEST="$HOME/Applications/CIFPreview.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ -d "$DEST" ]; then
    "$LSREG" -u "$DEST"
    rm -rf "$DEST"
    echo "removed $DEST"
else
    echo "not installed"
fi
killall quicklookd 2>/dev/null || true
echo "uninstalled (iRASPA's extension can be re-enabled with:"
echo "  pluginkit -e use -i nl.darkwing.iRASPA.macOS.iRASPAQuickLookExtension)"
