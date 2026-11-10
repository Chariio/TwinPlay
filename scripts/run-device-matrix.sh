#!/bin/bash
# TwinPlay device test matrix for the native-stack 3DS present fix.
# Run on the iMac when Charlie is back with the iPhone (target ~4:30 PM CT).
# Does NOT copy ROMs. Screenshots stay under $SHOTS; delete after review.
# Peek the foreground first; if FaceTime or a personal app is in front, wait and retry.
set -euo pipefail
UDID="${UDID:-00008160-00025D560C00000A}"
APP="${APP:-/tmp/twinplay-tests/DerivedData-vulkan/Build/Products/Debug-iphoneos/TwinPlay.app}"
SHOTS="${SHOTS:-/tmp/twinplay-tests/matrix-shots}"
LOG="${LOG:-/tmp/twinplay-tests/console}"
mkdir -p "$SHOTS" "$LOG"

shot() {
  local name="$1"
  xcrun devicectl device capture screenshot --device "$UDID" \
    --destination "$SHOTS/${name}.png" --display-unique-id 123-456-789
}

foreground_peek() {
  rm -f "$SHOTS/_fg.png"
  xcrun devicectl device capture screenshot --device "$UDID" \
    --destination "$SHOTS/_fg.png" --display-unique-id 123-456-789
  echo "Foreground peek is $SHOTS/_fg.png — inspect it. Abort if FaceTime/personal; delete it after."
}

terminate_twinplay() {
  local procjson="$LOG/procs-term.json"
  xcrun devicectl device info processes --device "$UDID" --json-output "$procjson" >/dev/null 2>&1 || true
  local pid
  pid=$(python3 -c '
import json,sys,re
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
found=[]
def rec(o):
    if isinstance(o, dict):
        blob=" ".join(str(v) for v in o.values() if not isinstance(v,(dict,list)))
        if "com.charlie.dsemu" in blob or "/TwinPlay.app" in blob or str(blob).endswith("TwinPlay"):
            for k,v in o.items():
                if str(k).lower() in ("pid","processidentifier","processid") and str(v).isdigit():
                    found.append(str(v))
        for v in o.values():
            rec(v)
    elif isinstance(o, list):
        for v in o:
            rec(v)
rec(d)
print(found[0] if found else "")
' "$procjson")
  if [[ -n "${pid}" ]]; then
    xcrun devicectl device process terminate --device "$UDID" --pid "$pid" --kill || true
  fi
  pkill -f "devicectl device process launch" 2>/dev/null || true
}

launch_game() {
  local rom="$1"
  shift
  # No --display (LCD-1 is the visible screen).
  xcrun devicectl device process launch --device "$UDID" --terminate-existing --console \
    com.charlie.dsemu -- -TPAutoBoot "$rom" -TwinPlayLogFPS YES "$@"
}

echo "===== $(date) ====="
if [[ ! -d "$APP" ]]; then
  echo "Missing $APP" >&2
  exit 1
fi
foreground_peek
xcrun devicectl device install app --device "$UDID" "$APP"

echo "===== Pokemon X (~40s, both screens?) ====="
launch_game "ROMs/Pokemon X (USA) (En,Ja,Fr,De,Es,It,Ko).cci" > "$LOG/matrix-pokemonx.log" 2>&1 &
LP=$!
sleep 40
shot pokemonx
kill "$LP" 2>/dev/null || true
terminate_twinplay
sleep 1

echo "===== Super Mario 3D Land (~40s, both screens aligned?) ====="
launch_game "ROMs/Super Mario 3D Land (USA) (En,Fr,Es) (Rev 1).cci" > "$LOG/matrix-sm3dl.log" 2>&1 &
LP=$!
sleep 40
shot sm3dl
kill "$LP" 2>/dev/null || true
terminate_twinplay
sleep 1

echo "===== Mario Kart 7 (~45s, tap hook should pass the logo) ====="
launch_game "ROMs/Mario Kart 7 (USA) (En,Fr,Es) (Rev 1).cci" -TPTestPressA YES > "$LOG/matrix-mk7.log" 2>&1 &
LP=$!
sleep 45
shot mk7
kill "$LP" 2>/dev/null || true
terminate_twinplay
sleep 1

echo "===== Super Mario 64 (~20s, one pause/resume) ====="
launch_game "ROMs/Super Mario 64 (USA).z64" -TPTestPause YES > "$LOG/matrix-sm64.log" 2>&1 &
LP=$!
sleep 10
shot sm64-before-pause
sleep 4
shot sm64-paused
sleep 8
shot sm64-resumed
kill "$LP" 2>/dev/null || true
terminate_twinplay
sleep 1

echo "===== GoldenEye 007 (~20s, image + pause) ====="
launch_game "ROMs/GoldenEye 007 (USA).z64" -TPTestPause YES > "$LOG/matrix-goldeneye.log" 2>&1 &
LP=$!
sleep 10
shot goldeneye-before-pause
sleep 4
shot goldeneye-paused
sleep 8
shot goldeneye-resumed
kill "$LP" 2>/dev/null || true
terminate_twinplay

echo "===== $(date) done ====="
echo "Screenshots in $SHOTS — review, then delete. Do not copy personal/home shots."
echo "If the peek (_fg.png) shows a personal photo, delete it immediately."
ls -la "$SHOTS"
