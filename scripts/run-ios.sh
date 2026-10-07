#!/bin/sh
# Build, install and launch the native app. npm shortcuts select live or demo mode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=live
REQUESTED_SIM="${SIMULATOR:-}"

usage() {
  cat <<'HELP'
Usage: npm run ios [-- --simulator NAME_OR_UDID]
       npm run ios:demo [-- --simulator NAME_OR_UDID]

ios       Build and launch with the configured live Firebase project.
ios:demo  Build and launch with local synthetic route data.

Choose a simulator with --simulator or the SIMULATOR environment variable.
By default, prefer Atlas iPhone 17, then iPhone 17, then another available iPhone.
Requires macOS, Xcode, an installed iOS Simulator runtime and Python 3.
Build output is saved to build/ios-build.log. Existing app data is preserved.
HELP
}

case "${1:-}" in
  live|demo) MODE="$1"; shift ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulator)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "--simulator needs a name or UDID." >&2; exit 2; }
      REQUESTED_SIM="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for TOOL in xcodebuild xcode-select xcrun python3 open; do
  command -v "$TOOL" >/dev/null 2>&1 || { echo "Required tool missing: $TOOL. See npm run ios -- --help." >&2; exit 1; }
done

DEVELOPER_PATH="$(xcode-select -p)"
XCODE_CONTENTS="${DEVELOPER_PATH%/Developer}"
VIEWER=""
for CANDIDATE in "$DEVELOPER_PATH/Applications/Simulator.app" \
  "$XCODE_CONTENTS/Applications/DeviceHub.app" "$XCODE_CONTENTS/Applications/Simulator.app"; do
  if [ -d "$CANDIDATE" ]; then VIEWER="$CANDIDATE"; break; fi
done
if [ -z "$VIEWER" ]; then
  echo "Simulator viewer not found in the selected Xcode. Select a full Xcode installation with xcode-select." >&2
  exit 1
fi

if [ "$MODE" = live ] && [ ! -f "$ROOT/ParcelPilot/GoogleService-Info.plist" ]; then
  echo "Live Firebase needs ParcelPilot/GoogleService-Info.plist. See docs/COST_AND_SETUP.md, or use npm run ios:demo." >&2
  exit 1
fi

DEVICE_LIST="$(xcrun simctl list devices available --json)"
SELECTION="$(printf '%s' "$DEVICE_LIST" | python3 -c '
import json, re, sys
request = sys.argv[1]
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(map(int, re.findall(r"\d+", runtime.rsplit(".iOS-", 1)[1])))
    devices.extend((version, d) for d in entries if d.get("isAvailable"))
devices.sort(key=lambda entry: entry[0], reverse=True)
chosen = None
if request:
    chosen = next((d for _, d in devices if request in (d["name"], d["udid"])), None)
else:
    for name in ("Atlas iPhone 17", "iPhone 17"):
        chosen = next((d for _, d in devices if d["name"] == name), None)
        if chosen:
            break
    if not chosen:
        phones = [d for _, d in devices if "iPhone" in d["name"]]
        chosen = next((d for d in phones if d["state"] == "Booted"), phones[0] if phones else None)
if not chosen:
    print("Simulator not found: " + request if request else "No available iPhone simulator. Install an iOS runtime in Xcode.", file=sys.stderr)
    sys.exit(1)
print(chosen["udid"])
print(chosen["name"].replace("\n", " "))
print(chosen["state"])
' "$REQUESTED_SIM")"
SIM_ID="$(printf '%s\n' "$SELECTION" | sed -n '1p')"
SIM_NAME="$(printf '%s\n' "$SELECTION" | sed -n '2p')"
SIM_STATE="$(printf '%s\n' "$SELECTION" | sed -n '3p')"

echo "Simulator: $SIM_NAME"
if [ "$SIM_STATE" != Booted ]; then
  echo "Booting simulator…"
  xcrun simctl boot "$SIM_ID"
fi
xcrun simctl bootstatus "$SIM_ID" -b
echo "Opening $(basename "$VIEWER" .app)…"
open -a "$VIEWER" --args -CurrentDeviceUDID "$SIM_ID"

mkdir -p "$ROOT/build"
echo "Building ParcelPilot ($MODE). Build output: $ROOT/build/ios-build.log"
if ! xcodebuild -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$ROOT/build/DerivedData.noindex" build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  > "$ROOT/build/ios-build.log" 2>&1; then
  echo "Build failed. Open $ROOT/build/ios-build.log for the Xcode error." >&2
  exit 1
fi

APP="$ROOT/build/DerivedData.noindex/Build/Products/Debug-iphonesimulator/ParcelPilot.app"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
echo "Installing ${BUNDLE}…"
xcrun simctl install "$SIM_ID" "$APP"

if [ "$MODE" = demo ]; then
  echo "Launching local demo data…"
  xcrun simctl launch --terminate-running-process "$SIM_ID" "$BUNDLE" \
    -PPDemoMode YES -PPSeedDemoRoute YES -PPResetDemoData NO \
    -PPUseFirebaseEmulators NO -PPSimulateOffline NO -PPDisableAnimations NO
else
  PROJECT="$(/usr/libexec/PlistBuddy -c 'Print PROJECT_ID' "$APP/GoogleService-Info.plist")"
  echo "Launching with live Firebase project: $PROJECT"
  xcrun simctl launch --terminate-running-process "$SIM_ID" "$BUNDLE" \
    -PPDemoMode NO -PPSeedDemoRoute NO -PPResetDemoData NO \
    -PPUseFirebaseEmulators NO -PPSimulateOffline NO -PPDisableAnimations NO
fi
echo "ParcelPilot launched on $SIM_NAME."
