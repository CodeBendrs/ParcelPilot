#!/bin/sh
# Captures demo-mode screenshots for design review on a compact and a large iPhone, in light, dark and
# accessibility text sizes. Output: build/screens/<device>/<state>.png
#   scripts/capture-screenshots.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData.noindex/Build/Products/Debug-iphonesimulator/ParcelPilot.app"
# The app's bundle ID: Config/Secrets.xcconfig overrides Config/Base.xcconfig.
BUNDLE="$(sed -n 's/^PP_BUNDLE_ID *= *//p' "$ROOT/Config/Base.xcconfig" "$ROOT/Config/Secrets.xcconfig" 2>/dev/null | tail -1)"
[ -d "$APP" ] || xcodebuild -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath "$ROOT/build/DerivedData.noindex" build CODE_SIGNING_ALLOWED=NO >/dev/null

for DEVICE in "${DEVICES:-PP iPhone SE}" "iPhone 17 Pro Max"; do
  OUT="$ROOT/build/screens/$(echo "$DEVICE" | tr ' ' '-')"
  mkdir -p "$OUT"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null
  xcrun simctl install "$DEVICE" "$APP"
  # Warm-up launch: the first launch after a cold boot can take longer than the per-shot wait.
  xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" -PPDemoMode YES -PPResetDemoData YES -PPSeedDemoRoute YES >/dev/null
  sleep 10
  for APPEARANCE in light dark; do
    xcrun simctl ui "$DEVICE" appearance "$APPEARANCE"
    for SIZE in large accessibility-extra-large; do
      xcrun simctl ui "$DEVICE" content_size "$SIZE"
      for STATE in plan deliver scan history settings; do
        case "$STATE" in
          plan) ARGS="" ;;
          deliver) ARGS="-PPInitialMode deliver" ;;
          *) ARGS="-PPInitialTab $STATE" ;;
        esac
        # shellcheck disable=SC2086
        xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE" -PPDemoMode YES -PPResetDemoData YES -PPSeedDemoRoute YES -PPDisableAnimations YES $ARGS >/dev/null
        sleep 4
        xcrun simctl io "$DEVICE" screenshot "$OUT/$STATE-$APPEARANCE-$SIZE.png" >/dev/null 2>&1
      done
    done
  done
  xcrun simctl ui "$DEVICE" appearance light
  xcrun simctl ui "$DEVICE" content_size large
  # Don't leave extra simulators running: they slow later test runs considerably.
  xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
done
echo "Screenshots in $ROOT/build/screens"
