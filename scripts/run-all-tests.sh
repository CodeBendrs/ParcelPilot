#!/bin/sh
# Runs every automated check available without cloud credentials.
#   scripts/run-all-tests.sh            (all)
# Requires: Xcode 26+, Node 22, a Java 21+ runtime for the Firebase emulators.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${SIMULATOR:-iPhone 17}"

echo "== ParcelPilotKit (swift test, includes Vision OCR on fixture labels)"
(cd "$ROOT/Packages/ParcelPilotKit" && swift test)

echo "== Cloud Functions unit tests"
(cd "$ROOT/firebase/functions" && npm ci --silent && npm run build && npm test)

echo "== Firestore + Storage security rules (emulator)"
(cd "$ROOT/firebase" && npm ci --silent && npm run test:rules)

echo "== Cloud Functions integration tests (emulator)"
(cd "$ROOT/firebase" && npm run test:functions:integration)

echo "== iOS app build, unit and UI tests ($SIM)"
xcodebuild test -project "$ROOT/ParcelPilot.xcodeproj" -scheme ParcelPilot \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$ROOT/build/DerivedData.noindex" \
  -resultBundlePath "$ROOT/build/results.noindex/AllTests-$(date +%s).xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

echo "Emulator end-to-end (real Firebase SDK + callables + rules): scripts/run-emulator-e2e.sh"
