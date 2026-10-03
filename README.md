# ParcelPilot

A native iPhone route planner for individual Canadian delivery drivers: scan package labels to add
stops, plan and optimize the route, deliver with large thumb-reach actions, and keep progress through
interruptions. Working name — see [Renaming](#renaming).

- **iOS app** — Swift 6 / SwiftUI, iOS 17+, VisionKit + Vision on-device OCR, Google Maps SDK for iOS,
  Firebase (Auth with Google and email sign-in — Sign in with Apple ready behind a setting —, Firestore
  with persistent cache, Storage, Functions, App Check,
  Crashlytics).
- **ParcelPilotKit** — Swift package with all domain logic (Canadian address parsing, recipient
  extraction, intake/dedupe, review policy, time zones, eligibility, proposal validation, demo optimizer).
- **Cloud Functions** — TypeScript, 2nd gen, `northamerica-northeast1`: `resolveAddress` (Geocoding
  API v4), `requestOptimization` (Route Optimization API), `deleteAccount`, `purgeExpiredProviderContent`.
- **Security rules** for Firestore and Storage, with emulator tests.

Status, verification evidence and remaining blockers: **[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)**.
Architecture, decisions and acceptance checklist: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Data model and retention: [docs/DATA_MODEL.md](docs/DATA_MODEL.md). Costs and cloud setup:
[docs/COST_AND_SETUP.md](docs/COST_AND_SETUP.md). Design system: [DESIGN.md](DESIGN.md). Real-device
checks: [docs/DEVICE_TEST_CHECKLIST.md](docs/DEVICE_TEST_CHECKLIST.md).

## Repository layout

```
ParcelPilot.xcodeproj         Xcode project (folder-synchronized groups; add files in Finder/Xcode freely)
ParcelPilot/                  App sources: App/, DesignSystem/, Features/, Services/{Core,Firebase,Demo}, Resources/
ParcelPilotTests/             App unit/integration tests (Swift Testing, run in the Simulator)
ParcelPilotUITests/           XCUITest driver flows with screenshot attachments
Packages/ParcelPilotKit/      Domain logic + tests (swift test on macOS, includes Vision OCR tests)
firebase/                     firebase.json, rules, indexes, rules tests, emulator scripts
firebase/functions/           Cloud Functions source (src/) and tests (test/, test/integration/)
fixtures/labels/              Synthetic shipping labels (fictional addresses) used by OCR tests
fixtures/shared/              Fixtures shared by Swift and TypeScript tests (time-zone/DST cases)
scripts/                      Test runners (run-all-tests.sh, run-emulator-e2e.sh), screenshots, fixture/icon generators
Config/                       Base.xcconfig (+ your git-ignored Secrets.xcconfig)
```

## Requirements

- Xcode 26 or later (built and tested with Xcode 27.0, Swift 6.4, iOS 26.5 Simulator).
- Node.js 22 (functions runtime `nodejs22`).
- Java 21+ for the Firebase Emulator Suite (`brew install openjdk@21`; the npm scripts find it
  automatically via `firebase/scripts-env.sh`).

## Run locally

### 1. Demo mode — no accounts, no network, no billing
Open `ParcelPilot.xcodeproj`, run the **ParcelPilot** scheme on an iPhone Simulator, tap
**Try demo mode** (or **Load sample demo route**). Everything stays on the device; locations are
synthetic and labelled as such; route order uses a clearly labelled straight-line estimate.

Command line equivalent:
```bash
xcodebuild -project ParcelPilot.xcodeproj -scheme ParcelPilot -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData.noindex build CODE_SIGNING_ALLOWED=NO
```
```bash
xcrun simctl install "iPhone 17" build/DerivedData.noindex/Build/Products/Debug-iphonesimulator/ParcelPilot.app
```
```bash
xcrun simctl launch "iPhone 17" com.example.parcelpilot -PPDemoMode YES -PPSeedDemoRoute YES
```
Useful launch arguments: `-PPResetDemoData YES`, `-PPSimulateOffline YES`, `-PPDisableAnimations YES`.

### 2. Local Firebase stack — real SDKs, rules and functions, still no billing
```bash
cd firebase && npm ci && npm --prefix functions ci && npm run build:functions
```
```bash
cd firebase && npm run emulators
```
The emulators use project `demo-parcelpilot` (cannot reach real services) and the functions use the
**emulator test provider** (`functions/.env.local`: `PROVIDER_MODE=emulator-fake`, synthetic results).
Firestore runs on port **8180**, Auth 9099, Functions 5001, Storage 9199, UI http://127.0.0.1:4000.
Then run the app with the launch arguments `-PPUseFirebaseEmulators YES` (enable it in the scheme's
Arguments tab, or):
```bash
xcrun simctl launch "iPhone 17" com.example.parcelpilot -PPUseFirebaseEmulators YES
```
Sign in with **Sign in with emulator test account** (anonymous auth, emulator only).

### 3. Production configuration
Follow [docs/COST_AND_SETUP.md](docs/COST_AND_SETUP.md): Firebase project in `northamerica-northeast1`,
Google + email sign-in, App Check, Route Optimization + Geocoding enabled for the functions' service
account, a restricted Maps SDK for iOS key. Put `GoogleService-Info.plist` in `ParcelPilot/` and copy
`Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`. Without these files the app shows an
actionable configuration screen (demo mode keeps working) — it never fakes success.

Joining the existing project as a second developer? See [docs/TEAM_SETUP.md](docs/TEAM_SETUP.md).

## Tests

| Suite | Command |
|---|---|
| Domain logic + Vision OCR on fixtures | `cd Packages/ParcelPilotKit && swift test` |
| Functions unit tests | `cd firebase/functions && npm test` |
| Security rules (Firestore + Storage, emulator) | `cd firebase && npm run test:rules` |
| Functions integration (callables against emulator) | `cd firebase && npm run test:functions:integration` |
| App unit/integration tests (Simulator) | `xcodebuild test -project ParcelPilot.xcodeproj -scheme ParcelPilot -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ParcelPilotTests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` |
| Driver UI flows with screenshots (Simulator, demo mode) | same with `-only-testing:ParcelPilotUITests/DriverFlowUITests -resultBundlePath build/results.noindex/UITests.xcresult` |
| Full local stack: Firebase iOS SDK + UI flow against the emulators, then server-side checks | `scripts/run-emulator-e2e.sh` (starts and stops the emulators itself) |
| Everything except the emulator UI run | `scripts/run-all-tests.sh` |
| Design-review screenshots (SE + Pro Max, light/dark, Large/AX3) | `scripts/capture-screenshots.sh` |

Builds are ad-hoc signed (`CODE_SIGN_IDENTITY=-`): Firebase Auth keeps its session in the keychain,
which unsigned Simulator builds can't use. Tested on iOS 26.5 and iOS 18.5 Simulators; latest results
are in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md#1-evidence--what-was-run).

Regenerate fixtures: `swift scripts/generate-label-fixtures.swift`; app icon: `swift scripts/generate-app-icon.swift`.

## Renaming
Display name, bundle ID and team live in `Config/Base.xcconfig` (`PP_APP_DISPLAY_NAME`, `PP_BUNDLE_ID`,
`PP_DEVELOPMENT_TEAM`). User-facing "ParcelPilot" strings are in `Features/Root/RootView.swift`,
`Features/Settings/SettingsView.swift` and `Info.plist` usage descriptions (build settings in the project).
Firebase project/function names are independent of the app name.

## Privacy and logging
OCR runs on the iPhone; label images and full OCR text are never stored or uploaded. Logs (`AppLog`) and
Crashlytics never include addresses, names, tracking numbers, notes/access codes or label text; dynamic
values are `.private`. Cloud Functions log only error classes. See the in-app "What ParcelPilot stores".

## Scope
In scope: individual drivers, one vehicle per route, Canada, iPhone. Out of scope for this build: fleet
dispatch, customer tracking, SMS, subscriptions, CarPlay, carrier integrations, background location,
in-app turn-by-turn navigation. Not App Store–ready until the blocked items in IMPLEMENTATION_STATUS.md
are verified.
