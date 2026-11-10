#!/bin/bash
# Generates DSEmu.xcodeproj from project.yml using XcodeGen.
# If XcodeGen isn't installed, downloads a pinned copy into ./.tools (no admin rights, free).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="2.46.0"
XCODEGEN="$(command -v xcodegen || true)"
if [ -z "$XCODEGEN" ]; then
  XCODEGEN="./.tools/xcodegen/bin/xcodegen"
  if [ ! -x "$XCODEGEN" ]; then
    echo "Downloading XcodeGen $VERSION..."
    mkdir -p .tools
    curl -fL "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" -o .tools/xcodegen.zip
    unzip -q -o .tools/xcodegen.zip -d .tools
    rm .tools/xcodegen.zip
    xattr -dr com.apple.quarantine .tools 2>/dev/null || true
  fi
fi
# TWINPLAY_WIDGET=0 leaves out the TwinPlay Games widget and the App Group, for signing setups that
# cannot provision them yet (no Apple account in Xcode). The app works the same without them.
# #19 iCloud saves: Supporting/TwinPlay.entitlements carries the iCloud container
# iCloud.com.charlie.dsemu (iCloud Documents). Automatic signing with -allowProvisioningUpdates
# registers it. TWINPLAY_ICLOUD=0 signs without iCloud (the app keeps saves on the device only).
if [ "${TWINPLAY_ICLOUD:-1}" = "0" ] && [ "${TWINPLAY_WIDGET:-1}" != "0" ]; then
  sed 's#CODE_SIGN_ENTITLEMENTS: Supporting/TwinPlay.entitlements#CODE_SIGN_ENTITLEMENTS: Supporting/TwinPlay.noicloud.entitlements#' project.yml > project.noicloud.yml
  "$XCODEGEN" generate --spec project.noicloud.yml
  rm -f project.noicloud.yml
  echo "Generated WITHOUT iCloud saves."
elif [ "${TWINPLAY_WIDGET:-1}" = "0" ]; then
  python3 - <<'PY'
import re
s = open("project.yml").read()
s = s.replace("      - target: TwinPlayWidget     # \"TwinPlay Games\" home screen widget (embedded in PlugIns)\n", "")
s = s.replace("        CODE_SIGN_ENTITLEMENTS: Supporting/TwinPlay.entitlements\n", "")
s = re.sub(r"\n  TwinPlayWidget:\n.*?(?=\n  TwinPlayTests:)", "", s, flags=re.S)
assert "TwinPlayWidget:" not in s and "target: TwinPlayWidget" not in s
open("project.nowidget.yml", "w").write(s)
PY
  "$XCODEGEN" generate --spec project.nowidget.yml
  rm -f project.nowidget.yml
  echo "Generated WITHOUT the widget / App Group."
else
  "$XCODEGEN" generate --spec project.yml
fi
echo "Done: open DSEmu.xcodeproj in Xcode."
