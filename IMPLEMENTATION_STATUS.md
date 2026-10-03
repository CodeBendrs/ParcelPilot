# Implementation status

Last updated **2026-10-03**. Local build only: nothing has been deployed, no billing-enabled resource
has been created, no paid Google Maps Platform API has been called, and no Firebase or Google Cloud
project of yours exists or was used. (Until a fix in §5, emulator runs sent failing App Check token
requests for the placeholder `demo-parcelpilot` project; demo mode loads Apple map tiles through
MapKit.) Not App Store–ready (see [Blocked](#3-blocked--needs-your-accounts-or-a-device) and
[Remaining](#4-remaining-work)).

Terms used below:
- **Verified** — exercised by an automated test or an inspected run listed in §1, on this Mac
  (Simulator, Swift package tests, or the Firebase Emulator Suite).
- **Implemented, unverified** — code exists and compiles; the behaviour needs something this machine
  doesn't have (a camera, an Apple Developer team, a billing-enabled Google Cloud project).
- **Blocked** — cannot be verified or completed without an action from you (§3).

## 1. Evidence — what was run

All commands were run from the repository root on macOS 27 with Xcode 27.0 (Swift 6.4), Node 22,
Java 21 for the emulators. Simulators: iPhone 17 (iOS 26.5), iPhone 16 (iOS **18.5**), iPhone SE 3rd
gen and iPhone 17 Pro Max (iOS 26.5, screenshots). No iOS 17 runtime is installed, so the iOS 17.0
deployment target is compiled for but not run.

| Suite | Command | Result (2026-10-03) |
|---|---|---|
| Domain logic + Vision OCR on synthetic label images | `cd Packages/ParcelPilotKit && swift test` | **91 / 91 passed** (13 suites) |
| Cloud Functions unit tests | `cd firebase/functions && npm test` | **38 / 38 passed** |
| Firestore + Storage security rules (emulator) | `cd firebase && npm run test:rules` | **21 / 21 passed** |
| Callable handlers against Firestore/Auth emulators (emulator-only fake providers) | `cd firebase && npm run test:functions:integration` | **26 / 26 passed** |
| App unit/integration tests (Simulator) | `xcodebuild test … -only-testing:ParcelPilotTests` | **22 passed** on iOS 26.5 and iOS 18.5 (+7 emulator tests, skipped unless enabled — next row) |
| Driver UI flows, demo mode (XCUITest) | `xcodebuild test … -only-testing:ParcelPilotUITests/DriverFlowUITests` | **6 / 6 passed** on iOS 26.5 and on iOS 18.5 |
| Full local stack: real Firebase iOS SDK ↔ Auth/Firestore (production rules)/Functions/Storage emulators | `scripts/run-emulator-e2e.sh` | **7 / 7** SDK-level tests, **2 / 2** UI flows (route end-to-end; email account), **9 / 9** server-side checks — exit 0; no Google service requests in the logs (also checked with Firebase debug logging on) |
| Layout review | `scripts/capture-screenshots.sh` (+ iOS 18.5 spot check) | All 40 screenshots of the final build reviewed: SE + Pro Max × light/dark × Large/AX3 × Plan, Deliver, Scan, History, Settings; problems found earlier were fixed (§5), remaining AX3 limits listed in §4 |

What the emulator run covers (`scripts/run-emulator-e2e.sh`):
- `FirestoreBackendEmulatorTests`: route edits increment `inputRevision` on the server; outcomes are
  append-only (second void rejected and reported); a write the rules reject is rolled back locally
  and reported in the sync journal; another user's route is unreadable/unwritable; a
  proof-of-delivery photo taken offline survives a relaunch, uploads under the Storage rules, gets its
  Firestore record, downloads in a fresh store and deletes; an account deleted on the server is
  detected as "sign in again"; an email account is created, gets its verification email, is refused
  address checks until it's confirmed, then allowed; wrong password, reset link and re-authentication.
- `EmulatorEndToEndUITests.testEmailAccountAgainstEmulators`: Continue with email → Create account →
  "confirm your email" banner → open the emailed link → I've confirmed it → banner clears → Settings
  shows the email → sign out → wrong password refused → sign in.
- `EmulatorEndToEndUITests.testEndToEndAgainstEmulators`: emulator sign-in → new route → paste 4 addresses (one with no civic
  number) → `resolveAddress` callable → optimize from the simulated current location →
  `requestOptimization` callable → proposal through the job document → apply → Delivered.
- `firebase/scripts/verify-emulator-e2e.mjs` then checks on the server: stops accepted by the rules;
  the no-civic address is `needsReview` (E4); nothing stored as `verified`; the outcome synced; the
  applied order and revision match; the job is labelled `emulatorFake`.

## 2. Status by area

IDs refer to the checklist in [docs/ARCHITECTURE.md §5](docs/ARCHITECTURE.md#5-feature-acceptance-checklist).

### Scanning
| ID | Status | Evidence / gap |
|---|---|---|
| S1 | Pipeline verified; live camera **implemented, unverified** | Capture → Vision OCR → analysis verified on synthetic label images (Kit "Label images", app "Scan pipeline"). VisionKit `DataScannerViewController` needs a physical iPhone. |
| S2 | Implemented, unverified | Framing guide, highlights, torch, zoom, shutter, camera stop on exit/background — device only. |
| S3–S5 | Verified | Recipient selection (headings, columns, sender rejection, ambiguity → choice), unit vs civic, French accents, PO box/RR/general delivery flags, postal normalization without silent correction. |
| S6 | Verified | Review required for partial, street/postal/city-only, conflicts, low confidence, RR, PO box; demo/emulator centroids stay coarse (fixed today). |
| S7 | Verified | Recognition, completeness and map match are separate (ReviewPolicy tests; "Map match" shown in the confirmation card UI test). |
| S8 | Verified (haptics device-only) | Confirmation card and batch mode with Undo and review queue (app tests). |
| S9 | Verified | Frame dedupe, repeated tracking ID, same destination → same stop, other unit → new stop. |
| S10 | Parsing verified; live barcode detection **unverified** | Tracking IDs, vCard/MECARD, GS1 postal codes from payloads (Kit). Vision barcode detection doesn't run in the Simulator. |
| S11 | Implemented (code review) | Label images and OCR text are never persisted or uploaded; logs mark dynamic values `.private`. No automated log audit. |
| S12 | Verified | Offline scans → durable drafts "Needs address verification", verified later, excluded from optimization. |
| S13 | Mostly verified | Simulator/no-camera fallback (UI test); glare, rotation, blur, incomplete (Kit). Denied/restricted camera are device checks. |

### Driver workflow
| ID | Status | Evidence / gap |
|---|---|---|
| A1–A3 | Verified | Create/rename/duplicate/archive/resume (app + emulator tests); manual entry and paste import (UI tests); CSV mapping/row errors/duplicates (Kit "Bulk import"). Import now sends uncertain rows to review instead of auto-confirming them (fixed today). |
| A3 address suggestions | Verified on emulator; **live Google call unverified** | Typing in "Search an address" or the start/end search shows Google address suggestions (`suggestAddresses` callable → Places API (New) Autocomplete, Canada and street addresses only, debounced, capped at 500/day/user and 9,000/month project-wide). Picking one resolves its place ID and opens the card already checked. Emulator UI test `testAddressSuggestionAgainstEmulators`; request/response mapping unit-tested. Needs Places API (New) enabled and the function deployed. |
| A4 | Implemented, lightly tested | Package fields are stored and shown; no UI test edits every field. |
| B1–B5 | Verified | Map + list (screenshots), pins/windows/service time/break (Kit + functions), preview with changed positions, savings only with a computed baseline, invalidation by revision. |
| C1–C5 | Verified, except the Maps round trip | Next-stop card, Delivered/Failed (reason)/Skip with Undo, package outcomes, retry/exclude, resume after relaunch (UI + app tests); re-plan remaining (functions integration). Returning from Apple/Google Maps is a device check (URLs are unit-tested). |
| D1, D2, D4 | Verified | History summary with distance source, settings, demo mode (UI tests). |
| D3 | Email sign-in verified on emulator; **Google needs your Firebase project**; Apple optional | Email accounts: create, verification email, "confirm your email" banner, sign in, wrong password, reset link, re-authentication (SDK + UI tests against the Auth emulator). The server refuses address checks and optimization until an email account is confirmed (emulator test). `deleteAccount` removes Firestore/Storage/Auth data (integration test). **Continue with Google** is implemented with Google's official button but can only run against your real Firebase project. Sign in with Apple and App Attest are switched off (`PP_APPLE_DEVELOPER_PROGRAM = NO`) so a free personal team can sign the app. An unusable saved sign-in shows "Sign in again", or an explanation on the sign-in screen when Firebase signs the user out itself (emulator-tested). |
| D5 | Verified on emulator (camera capture device-only) | Durable pending upload, Storage rules, record, download, delete (emulator test); EXIF/GPS stripped (app test). |

### Routing correctness
| ID | Status | Evidence / gap |
|---|---|---|
| R1 | Implemented; **live calls blocked** | Production path calls Route Optimization `optimizeTours` with ADC. Request building and response interpretation are unit-tested against Google's documented shapes; no live call has been made (needs billing — §3). Demo heuristic is labelled everywhere. |
| R2–R5 | Verified (mocked provider) | Every eligible stop exactly once or explained, mandatory shipments, non-zero objective, windows/breaks/pins as constraints, infeasibility with suggestions, remaining-work optimization, stable IDs, revision checks, idempotent request IDs. |
| R6 | Verified | Shared DST/midnight fixtures used by both Swift and TypeScript tests; device-authoritative wall-clock conversion. |
| R7 | Verified | Traffic wording tested; the fake and demo providers never claim traffic. |
| R8 | Verified (mocked provider) | Limit validation, timeouts scaled by size, bounded retries only for unbilled transient errors, quota exhaustion, duplicate-tap protection, last usable plan kept. |

### Data / backend, design
| ID | Status | Evidence / gap |
|---|---|---|
| F1–F4 | Verified | Schema + retention ([docs/DATA_MODEL.md](docs/DATA_MODEL.md)), rules tests, callable tests, persistent cache with pending/synced/rejected states (emulator tests). |
| F5 | Verified | Camera/location requested at the point of use; manual paths without either (UI tests). |
| G1 | Partly verified | Light/dark, Dynamic Type to AX3, 44 pt targets, non-colour status inspected in screenshots. VoiceOver and Reduce Motion not audited with the screen reader running. |
| G2, G3 | Verified | Every empty/error/offline/permission state has an action; screenshots inspected on compact and large iPhones. |

### Acceptance scenarios
| Scenario | Status | Evidence |
|---|---|---|
| E1 Toronto return + Victoria SHIP TO, UNIT 204 | Verified (images) | Kit label-image test, app scan pipeline normal mode; synthetic location never "verified". |
| E2 French label, APP. 12 | Verified (images) | Kit label tests; uncertain readings go to review. |
| E3 Duplicate tracking / same destination / other unit | Verified | Kit + app RouteStore + batch-mode tests. |
| E4 Unreadable civic + readable postal; tracking-only barcode | Verified | Kit, app import test, and the emulator end-to-end server check. |
| E5 Batch auto-add + Undo; ambiguous → review | Verified | App scan pipeline tests. |
| E6 Offline delivered → terminate → reopen → sync once | Verified | App relaunch test (on-device store) + emulator outcome tests (Firestore). Airplane-mode run on a device still listed in the checklist. |
| E7 Incompatible hard windows | Verified | Kit + functions integration. |
| E8 Edit during optimization → stale | Verified | Kit + functions integration (edit preserved). |
| E9 Navigation hand-off | Partly verified | URL/handoff tests; opening the other app and returning is a device check. |
| E10 Cross-user denial, quotas, missing config | Verified | Rules tests, callable integration tests, Firebase SDK emulator test. |
| E11 10/50/200-stop timings | **Mocked only; live blocked** | See §2.1. |

### 2.1 E11 timings (mocked vs live)

| Stops | Server handler, **mocked provider** (`requestOptimization` against emulator Firestore with the emulator-only fake optimizer) | On-device **demo heuristic** (straight-line, debug build, Mac) | Live Google Route Optimization |
|---|---|---|---|
| 10 | 37 ms | 0.3 ms | **not measured — blocked** |
| 50 | 45 ms | 4–6 ms | **not measured — blocked** |
| 200 | 54 ms | 52–54 ms (1.5 s with soft deadlines, its time budget) | **not measured — blocked** |

The mocked column measures ParcelPilot's own work (validation, reads, quota transaction, lock, request
building, exactly-once verification, job write) — it excludes Google's solver time and network
latency, which dominate in production. Source: the "E11 timings" tests in
`firebase/functions/test/integration/handlers.test.ts` and `RoutingTests.swift`.

## 3. Blocked — needs your accounts or a device

| Item | Why it's blocked | What unblocks it |
|---|---|---|
| Live Route Optimization + Geocoding | Requires a Google Cloud project with billing; you asked not to activate paid services. | Follow [docs/COST_AND_SETUP.md](docs/COST_AND_SETUP.md) §2–3 and §5 (Blaze plan, APIs, runtime service account with `roles/routeoptimization.editor`), deploy, then run the "Map and routing" device checks and record live 10/50/200 timings here. |
| Google map rendering (Maps SDK for iOS) — implemented, unverified | Needs a restricted iOS API key. Without it, production builds show "The map needs a Maps SDK for iOS key…" in the map area (stops, scanning and delivery still work). Apple Maps is used only for synthetic demo/emulator data, never for Google content. | Create the key (setup §3) and put it in `Config/Secrets.xcconfig`. |
| Google sign-in — implemented, unverified | Needs your Firebase project: Google enabled in Authentication, `GoogleService-Info.plist` downloaded *after* enabling it, and its `REVERSED_CLIENT_ID` in `Config/Secrets.xcconfig`. Without these the button is disabled and says what's missing. | Setup guide §4. |
| Sign in with Apple + App Attest (switched off) | Need the paid Apple Developer Program. Apple's App Store guideline 4.8 generally expects Sign in with Apple when Google sign-in is offered, so plan to switch it on before submitting. | Paid membership, then `PP_APPLE_DEVELOPER_PROGRAM = YES` (setup guide §4). |
| App Check enforcement | Release builds can't get App Check tokens without the paid Apple Developer Program (App Attest, or a DeviceCheck key). Debug builds use the debug provider (register its token); emulator mode uses no App Check. | Until then deploy with `ENFORCE_APP_CHECK=false` (server quotas still apply); with the paid membership, register App Attest and set it to `true`. |
| Crashlytics reporting | Needs the production Firebase project. | Setup §2.6. |
| Physical camera: live scanning, barcodes, torch, haptics, camera indicator | The Simulator has no camera and doesn't run Vision barcode detection. | [docs/DEVICE_TEST_CHECKLIST.md](docs/DEVICE_TEST_CHECKLIST.md) — **none of it has been run yet.** |
| Navigation app round trip, real-world offline (airplane mode) | Device behaviour. | Device checklist "Navigation hand-off" and "Offline". |
| Deployment | Not requested. | Setup §5, only when you decide. |

## 4. Remaining work

Not blocked by an external dependency, but not done in this build:
- **French UI localization.** Labels are read in English and French, but the app's own text is
  English only (no string catalog yet).
- **VoiceOver / Reduce Motion audit** with the screen reader running, on a device.
- **iOS 17 runtime run.** Built for iOS 17.0; tested on iOS 18.5 and 26.5 only (no iOS 17 Simulator
  runtime installed here).
- **iPhone SE at AX3+:** in Deliver the next stop's street line sits just below the fold at half
  panel height (unit badge visible), and on Scan the "Allow camera" button needs a scroll inside the
  camera card (Import and Type stay visible). Both scroll; neither is cut off.
- **Privacy manifest review.** `ParcelPilot/Resources/PrivacyInfo.xcprivacy` declares collected data
  (user ID, precise location when optimizing from it, photos, delivery content, crash data) and the
  UserDefaults reason; confirm it against your final App Store Connect privacy answers.
- **Sign in with Apple before App Store submission** (guideline 4.8), once you have the paid
  Apple Developer Program — the code is in place behind `PP_APPLE_DEVELOPER_PROGRAM`.
- **App Store submission items:** screenshots for the store, support URL, privacy policy text,
  export-compliance answers, TestFlight round. Not started.

## 5. Defects found by verification and fixed

Found while running the checks above (all re-verified after the fix):
- **Route revision counter reset on every edit (Firestore).** Combining `FieldValue.increment` with a
  `mergeFields` write cleared the field first, so `inputRevision` stayed at 1 and stale plans could
  look current. The increment is now its own write in the same atomic batch
  (`FirestoreRouteBackend`); covered by an SDK-level emulator test and a server-side check.
- **Demo/emulator postal-code centroids were treated as buildings.** `MatchAssessor` labelled every
  synthetic result `.synthetic` before checking granularity, so an address with no civic number
  could be accepted as a destination in demo/emulator mode (E4). Coarse results now stay coarse.
- **Bulk import auto-confirmed addresses that needed review**, and saving an edited address could
  count an unseen check as driver-confirmed. Both now go to review unless the driver saw the result.
- **A saved sign-in whose account no longer exists stalled silently.** Firebase reports an unknown
  refresh token as an internal error, so the app stayed "signed in" while nothing synced and every
  address check failed as "offline". The session is now validated at sign-in, on foreground and when
  a callable is refused; the driver gets a "Sign in again" banner (re-authenticate with the same
  Apple ID so queued changes sync, or sign out). When Firebase signs a deleted/disabled account out
  on its own, the sign-in screen now says why.
- **Emulator mode contacted Google's App Check service** (debug-token exchanges for the `demo-`
  project). Emulator builds and the emulator tests now use no App Check provider; no Google requests
  appear in the emulator run's logs.
- **Demo heuristic took ~10 s for 200 stops** (2-opt re-simulated the whole route for every move).
  Exact distance-delta 2-opt without time constraints, an allocation-free cost function with a 1.5 s
  budget otherwise: 52 ms for 200 stops.
- **Accessibility-size layout:** Optimize, Batch and banner actions wrapped mid-word; the next stop
  was hidden behind the action bar on iPhone SE; the demo-map badge covered the map; camera
  explanations were truncated. Rules now in [DESIGN.md](DESIGN.md#accessibility).
- **Missing privacy manifest** — added.
- **Crash in the new "confirm your email" banner** (it read a value from SwiftUI's environment
  outside the part of the screen where that value is set). Caught by the new email UI test before
  it ever reached a device; fixed by moving where the value is provided.
- Test tooling: the functions unit script collected the emulator-only suite; the end-to-end check
  inspected other tests' users; UI tests matched section headers case-sensitively (iOS 18
  upper-cases them); the emulator script now resets the Simulator keychain so a previous run's
  session can't leak in.

Earlier in the build (already reflected in the code): Vision cold-start and Cyrillic look-alike
characters in OCR, rotation retries choosing worse readings, glare detection, rules allowing photo
overwrite, Firestore TLS to the emulator, `createdAt` drift rejected by the rules, MainActor
crashes in dynamic colours and network callbacks, sheets dismissing themselves, toasts covering
actions.

### Test environment note
Spotlight indexing of build output pushed this Mac's load average above 200 several times, which
slowed Simulator tests 10–15× and made XCUITest time out waiting for the app to go idle (one
emulator end-to-end run timed out that way and passed on rerun once the load dropped; the earlier
"stale session" failures were a real bug, fixed above). A rerun also exposed a race in the
cross-user SDK test (both users shared one Firebase app, so a request could still carry the
previous user's token); each test environment now uses its own Firebase app instance. Build
products and result bundles now live in `build/DerivedData.noindex` and `build/results.noindex`,
which Spotlight skips. If runs are still
slow, add the project's `build` folder under System Settings → Spotlight → Search Privacy.

## 6. How to reproduce

```bash
scripts/run-all-tests.sh
```
```bash
scripts/run-emulator-e2e.sh
```
```bash
scripts/capture-screenshots.sh
```
`run-all-tests.sh` runs everything that needs no emulator UI session (Kit, functions unit, rules,
functions integration, app unit + UI). `run-emulator-e2e.sh` starts the emulators itself, uninstalls
the app and resets the Simulator keychain first, and stops the emulators when done.
