#!/bin/sh
# Captures stable demo screens on compact and large iPhones, light/dark, Large/AX3.
# XCTest waits for each screen's controls before capturing, so launch screens aren't accepted.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$(date +%s)"

for DEVICE in "${DEVICES:-PP iPhone SE}" "iPhone 17 Pro Max"; do
  OUT="$ROOT/build/screens/$(echo "$DEVICE" | tr ' ' '-')"
  mkdir -p "$OUT"
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null
  xcrun simctl location "$DEVICE" set 48.4284,-123.3656
  for APPEARANCE in light dark; do
    xcrun simctl ui "$DEVICE" appearance "$APPEARANCE"
    for SIZE in large accessibility-extra-large; do
      xcrun simctl ui "$DEVICE" content_size "$SIZE"
      RESULT="$ROOT/build/results.noindex/Screens-$RUN-$(echo "$DEVICE" | tr ' ' '-')-$APPEARANCE-$SIZE.xcresult"
      ATTACHMENTS="$OUT/attachments-$RUN-$APPEARANCE-$SIZE"
      echo "Capturing $DEVICE / $APPEARANCE / $SIZE"
      TEST_RUNNER_PP_UI_SCREEN_MATRIX=1 xcodebuild test \
        -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot \
        -destination "platform=iOS Simulator,name=$DEVICE" \
        -derivedDataPath "$ROOT/build/DerivedData.noindex" \
        -only-testing:ParcelPilotUITests/DriverFlowUITests/testPrimaryScreensForScreenshotAudit \
        -parallel-testing-enabled NO -collect-test-diagnostics never -enableCodeCoverage NO -resultBundlePath "$RESULT" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= > "$RESULT.log" 2>&1
      xcrun xcresulttool export attachments --path "$RESULT" --output-path "$ATTACHMENTS" >/dev/null
      python3 - "$ATTACHMENTS" "$OUT" "$APPEARANCE" "$SIZE" <<'PY'
import json, shutil, sys
from pathlib import Path
source, output = map(Path, sys.argv[1:3])
appearance, size = sys.argv[3:5]
written = set()
for test in json.loads((source / 'manifest.json').read_text()):
    for attachment in test['attachments']:
        name = attachment['suggestedHumanReadableName']
        if name.startswith('matrix-') and attachment['exportedFileName'].endswith('.png'):
            state = name.split('_', 1)[0].removeprefix('matrix-')
            shutil.copyfile(source / attachment['exportedFileName'], output / f'{state}-{appearance}-{size}.png')
            written.add(state)
expected = {'plan', 'plan-list', 'deliver', 'partial', 'stops', 'optimize', 'address-review', 'scan', 'history', 'settings'}
if written != expected:
    raise SystemExit(f'Missing screenshots: {expected - written}')
PY
    done
  done
  xcrun simctl ui "$DEVICE" appearance light
  xcrun simctl ui "$DEVICE" content_size large
  xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
done
echo "Screenshots in $ROOT/build/screens"
