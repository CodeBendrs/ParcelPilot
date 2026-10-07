#!/bin/sh
# Full stack on this Mac, no cloud credentials: starts the Firebase Emulator Suite (Auth, Firestore
# with the production rules, Cloud Functions with the emulator-only test providers, Storage), then
#   1. ParcelPilotTests/FirestoreBackendEmulatorTests — the app's Firestore backend through the real
#      Firebase iOS SDK (revision increments, append-only outcomes, rejected writes, cross-user access)
#   2. ParcelPilotUITests/EmulatorEndToEndUITests — sign in → new route → paste 4 addresses →
#      resolveAddress → requestOptimization → apply → Delivered
#   3. firebase/scripts/verify-emulator-e2e.mjs — checks the documents the UI flow left on the server
# Ad-hoc signing is required: Firebase Auth stores its session in the keychain.
#   scripts/run-emulator-e2e.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${SIMULATOR:-iPhone 17}"
# The app's bundle ID: Config/Secrets.xcconfig overrides Config/Base.xcconfig.
BUNDLE="$(sed -n 's/^PP_BUNDLE_ID *= *//p' "$ROOT/Config/Base.xcconfig" "$ROOT/Config/Secrets.xcconfig" 2>/dev/null | tail -1)"
mkdir -p "$ROOT/build"

(cd "$ROOT/firebase" && npm ci --silent && npm run build:functions >/dev/null)
(cd "$ROOT/firebase" && ./scripts-env.sh npx firebase emulators:start --project demo-parcelpilot \
  --only auth,firestore,functions,storage > "$ROOT/build/emulators.log" 2>&1) &
EMU_PID=$!
trap 'kill $EMU_PID 2>/dev/null || true; pkill -f "emulators:start --project demo-parcelpilot" 2>/dev/null || true' EXIT

echo "Waiting for the emulators…"
i=0
until curl -sf "http://127.0.0.1:5001/" >/dev/null 2>&1 || grep -q "All emulators ready" "$ROOT/build/emulators.log" 2>/dev/null; do
  i=$((i + 1)); [ $i -gt 120 ] && { echo "Emulators did not start; see build/emulators.log"; exit 1; }
  sleep 1
done

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl uninstall "$SIM" "$BUNDLE" 2>/dev/null || true
# Uninstalling doesn't clear the Simulator keychain, where Firebase Auth keeps its session; a session
# from an earlier emulator run would point at an account this fresh emulator doesn't have.
xcrun simctl keychain "$SIM" reset
xcrun simctl location "$SIM" set 48.4284,-123.3656

xcodebuild build-for-testing -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$ROOT/build/DerivedData.noindex" \
  -enableCodeCoverage NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  > "$ROOT/build/emulator-build.log" 2>&1
xcrun simctl install "$SIM" "$ROOT/build/DerivedData.noindex/Build/Products/Debug-iphonesimulator/ParcelPilot.app"
xcrun simctl privacy "$SIM" grant location "$BUNDLE"

TEST_RUNNER_PP_EMULATOR=1 xcodebuild test-without-building -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$ROOT/build/DerivedData.noindex" \
  -parallel-testing-enabled NO -collect-test-diagnostics never -enableCodeCoverage NO \
  -only-testing:ParcelPilotTests/FirestoreBackendEmulatorTests \
  -only-testing:ParcelPilotUITests/EmulatorEndToEndUITests \
  -resultBundlePath "$ROOT/build/results.noindex/EmulatorE2E-$(date +%s).xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

node "$ROOT/firebase/scripts/verify-emulator-e2e.mjs"
