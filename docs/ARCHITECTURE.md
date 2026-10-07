# ParcelPilot architecture plan

Working document. Records the architecture, assumptions and the acceptance checklist the build is
verified against. Status of each item lives in `IMPLEMENTATION_STATUS.md`.

## 1. System overview

```
┌──────────────────────────── iPhone (Swift / SwiftUI, iOS 17+) ─────────────────────────────┐
│ Features (SwiftUI views + @Observable view models)                                          │
│   Auth · Routes · Planning (map + sheet) · Add stops (scan / search / paste / CSV)          │
│   Review queue · Delivering · Package finder · Proof of delivery · History · Settings       │
│                                                                                             │
│ AppServices (protocols, chosen once at launch by AppMode)                                   │
│   RouteRepository · AddressResolver · RouteOptimizer · PhotoStore · AccountService          │
│   ┌──────────── production / emulator ──────────┐  ┌───────────── demo ──────────────┐      │
│   │ Firestore (persistent cache) + SyncJournal   │  │ LocalRouteRepository (JSON file) │      │
│   │ Callable resolveAddress / requestOptimization│  │ DemoAddressResolver (synthetic)  │      │
│   │ Cloud Storage photos + PendingUploadQueue    │  │ DemoOptimizer (straight-line)    │      │
│   │ Google / email (/ Apple) → Firebase Auth     │  │ Local photo store                │      │
│   └──────────────────────────────────────────────┘  └──────────────────────────────────┘      │
│ DraftStore (durable, on-device): scanned-but-unconfirmed labels (review queue)              │
│                                                                                             │
│ ParcelPilotKit (Swift package, no Firebase): models, Canadian address parsing, label        │
│   recipient extraction, Vision OCR adapter, intake/dedupe, CSV/paste import, match          │
│   assessment, review policy, time-zone math, eligibility, proposal validation, demo         │
│   optimizer, delivery progress derivation, navigation URL building.                         │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
                 │ HTTPS callable (Firebase Auth ID token + App Check token)
┌──────────── Firebase (northamerica-northeast1, Montréal) ───────────────────────────────────┐
│ Cloud Functions gen2 (TypeScript)                                                           │
│   resolveAddress ─────► Geocoding API v4 (OAuth via function runtime identity)              │
│   requestOptimization ► Route Optimization API optimizeTours (OAuth, runtime identity)      │
│   deleteAccount · purgeExpiredProviderContent (scheduled)                                   │
│ Firestore users/{uid}/… (strict owner rules) · Cloud Storage users/{uid}/… (owner rules)    │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 2. App modes

| Mode | When | Data | Address resolution | Optimizer | Map |
|---|---|---|---|---|---|
| **Production** | `GoogleService-Info.plist` present, not demo | Firestore + Storage | Google Geocoding v4 via `resolveAddress` | Google Route Optimization via `requestOptimization` | Google Maps SDK (key from `Config/Secrets.xcconfig`) |
| **Emulator** | launch argument `-PPUseFirebaseEmulators YES` | Local Firebase Emulator Suite, project `demo-parcelpilot` | Functions in emulator; Google calls only if credentials exist, otherwise the explicitly labelled *emulator test provider* (`PROVIDER_MODE=emulator-fake`, refused outside the emulator) | same | Google map if key present, else list-only with configuration notice |
| **Demo** | user taps "Try demo mode" | JSON file on device | `DemoAddressResolver` — synthetic coordinates, **never** reported as verified real addresses | `DemoOptimizer` — straight-line heuristic, labelled "Demo estimate" | Apple MapKit (no Google content exists in demo mode) |
| **Unconfigured** | production selected but plist/keys missing | — | — | — | Actionable configuration screen; demo remains available |

Google content (geocodes, ETAs, polylines) is only ever drawn on a Google map. Demo content uses MapKit.

## 3. Key decisions

1. **Packages ≠ stops.** A stop is a delivery destination identified by a normalized *destination key*
   (civic number + street + unit + postal code). A package belongs to exactly one stop. Different units
   are different stops. Coordinates never merge stops.
2. **Append-only delivery outcomes.** `outcomes/{id}` are created once (client UUID), may only be voided
   (`voidedAt`), never edited or deleted by clients. Package status = latest non-voided outcome. Retry
   and exclusion are themselves outcomes (`requeued`, `excluded`). Firestore persistent cache keeps
   pending writes across termination; deterministic IDs make replays idempotent.
3. **Input revisions.** `route.inputRevision` increments on any change to addresses, constraints, stop
   set or route settings. Optimization jobs record the revision; the function re-checks it in a
   transaction before writing the result, and the client re-checks before applying. Proposals that
   include stops completed after the request are stale.
4. **Optimization runs server-side** in `requestOptimization` (idempotent by client `requestId`), state
   is observable in `users/{uid}/optimizationRequests/{requestId}` (server-write-only). The client shows
   a preview; applying it rewrites only `stop.sequence` of remaining stops.
5. **Pins as anchored segments.** Google documents that precedence rules covering many shipments may be
   rejected, so first/last pins and an explicitly fixed next stop are enforced structurally: a
   1-shipment prefix request (origin → first), the main request starting at the first stop at its
   computed departure time and ending at the last stop's location, and a 1-shipment suffix (last stop
   → route end). ETAs stay exact; nothing is swapped after solving.
6. **Mandatory shipments, meaningful objective.** No `penaltyCost` (shipments mandatory). Vehicle
   `costPerHour` and `costPerKilometer` are always non-zero. Hard windows → `timeWindows.startTime/endTime`;
   "prefer earlier" → `softEndTime` + `costPerHourAfterSoftEndTime`.
7. **Local wall-clock constraints.** Times are stored as wall-clock minutes from local midnight of the
   route's service date in the route's IANA time zone (values ≥ 1440 mean next day). Both Swift and
   TypeScript resolve them with the same DST policy (nonexistent → shift forward, ambiguous → earlier
   occurrence) and are tested against one shared fixture file.
8. **Provider content retention.** Place IDs: kept. Geocoded lat/lng: `expiresAt` = +30 days, then
   stripped server-side and ignored client-side (refreshed by place ID). Optimization proposals (ETAs,
   distances, polylines): `expiresAt` = +24 h (Firestore TTL + client check). Driver-entered addresses,
   notes, packages, outcomes and driver-placed pins are user data.
9. **Navigation handoff** passes the driver-confirmed street address text (unit omitted from the
   query, kept on the stop card). Apple Maps never receives Google coordinates or place IDs; Google Maps
   may receive the place ID.
10. **Scanning stays on device.** VisionKit `DataScannerViewController` for live preview/barcodes,
    Vision `VNRecognizeTextRequest` on captured frames for confidence + candidates. Label images and full
    OCR text are never persisted or uploaded; only the selected destination and package fields are.
11. **Single source of truth per lifecycle stage.** DraftStore owns unconfirmed scans; once confirmed
    they become Stop/Package writes in the RouteRepository and the draft is deleted. Firestore's
    persistent cache owns pending application writes; `SyncJournal` only records outcome-critical
    operations so rejected or unverified writes can be surfaced and retried.
12. **Server limits are hard, app-enforced.** Per-user daily and project-wide monthly counters are
    reserved in Firestore transactions *before* any paid call. Billing alerts are additionally
    recommended but are not a cap.

## 4. Assumptions

- Initial product limit: 200 unique eligible stops and 400 packages per route (configurable on the
  server via params and mirrored in the app).
- One driver, one vehicle per route; Canadian addresses only (`regionCode=CA`).
- Driver's device clock is approximately correct; outcome order uses device `recordedAt` and server
  `serverRecordedAt` for audit.
- Traffic: `considerRoadTraffic` is user-selectable; results are labelled "traffic-aware estimate for
  the departure time" when on and "typical travel times" when off — never "live traffic".
- Region: Firestore/Functions/Storage in `northamerica-northeast1`. Google Maps Platform web services are
  global endpoints; processing location is not guaranteed to be Canada.
- No billing-enabled resources are created by this build. Deployment requires explicit instruction.

## 5. Feature acceptance checklist

Checked = verified locally (Simulator, Swift package tests or the Firebase Emulator Suite). Unchecked
items note what's missing. Evidence and commands: [IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md).

### Scanning
- [ ] S1 Live scanning via DataScanner with support/availability checks; capture→Vision OCR pipeline — *pipeline verified on images; live camera needs a device*
- [ ] S2 Framing guide, recognition highlights, torch/zoom/shutter, camera released on exit/background — *device only, unverified*
- [x] S3 Recipient block selection by headings + spatial grouping; sender/return blocks rejected; ambiguity → choice
- [x] S4 Field extraction incl. unit vs civic, French accents, province, postal code, PO box/RR flags
- [x] S5 Postal normalization (A1A 1A1), no silent correction of uncertain characters
- [x] S6 Raw vs resolved comparison; review required for partial/postal-centroid/low-confidence/conflicts/RR/PO box
- [x] S7 Three separate signals: recognition, completeness, map match (no fake probabilities)
- [x] S8 Confirmation card (normal) + batch mode with auto-add, haptic, Undo, review queue
- [x] S9 Frame dedupe; tracking-ID duplicate warning; same destination → same stop; different unit → new stop
- [ ] S10 Barcodes: tracking IDs only, explicit address payloads (vCard/MECARD) only when present — *payload parsing verified; live barcode detection needs a device*
- [ ] S11 Ephemeral label images/OCR; no PII in logs/analytics — *implemented; code review only*
- [x] S12 Offline scan → local draft "Needs address verification", resolved later, excluded from optimization
- [ ] S13 Denied/restricted/simulator/glare/rotation/blur/incomplete/cancel paths; synthetic fixtures; device checklist — *verified except denied/restricted camera (device)*

### Driver workflow
- [x] A1 Routes: create, rename, duplicate, archive, resume
- [x] A2 Start/end, return-to-start, departure, time zone, default service time, break
- [x] A3 Add stops via scan, manual search, multiline paste, CSV (column mapping, row errors, duplicate review)
- [ ] A4 Package fields: tracking ID, count, size, storage location, notes — *implemented, lightly tested*
- [x] B1 Map with numbered stops + synchronized ordered list sheet
- [x] B2 Stop edit, manual reorder, first/last pin, hard window vs soft deadline, service duration, break
- [x] B3 Duration, distance, completion estimate, warnings, calculation time
- [x] B4 Optimization preview with changed positions; savings only with computed baseline
- [x] B5 Invalidation on address/constraint/stop-set change
- [x] C1 Next-stop card: address, unit, package count, storage location, notes
- [ ] C2 Navigate / Delivered / Failed (reason) / Skip with Undo; returning from Maps never completes — *verified except the round trip through the Maps app (device)*
- [x] C3 Package-level outcomes; stop complete only when packages handled
- [x] C4 Re-optimize remaining from current location or chosen origin; fixed next stop; completed preserved
- [x] C5 Skipped/failed retry or exclude; resume after relaunch; actual timestamps
- [x] D1 History summaries with distance source
- [x] D2 Settings: navigation app, units, default service duration
- [ ] D3 Sign-in (Google, email; Apple when enabled), sign out, account + data deletion (incl. Apple token revocation) — *email sign-in and deletion verified on emulator; production Firebase project exists, live sign-in unverified; Sign in with Apple needs the paid Apple Developer Program (Apple Developer team)*
- [x] D4 Demo mode without credentials, clearly identified
- [x] D5 Proof-of-delivery photos: capture, upload, view, delete, durable pending-upload recovery — *camera capture is device-only*

### Routing correctness
- [ ] R1 Real road-network optimizer (Google) in production; demo heuristic labelled — *functions confirmed ACTIVE in Google-provider mode on October 4; successful live Google requests and production configuration remain unverified; see IMPLEMENTATION_STATUS.md*
- [x] R2 Every eligible stop exactly once or explained; mandatory shipments; non-zero objective
- [x] R3 Start/end, hard windows, service duration, breaks, pins as real constraints
- [x] R4 Infeasibility reported with suggested changes; nothing dropped silently
- [x] R5 Remaining-work optimization; stable IDs; revision checks; request IDs
- [x] R6 Time-zone, DST and midnight-crossing conversions tested
- [x] R7 Honest traffic labelling; no "best route" claims
- [x] R8 Provider limit validation; timeout/cancel/quota/provider errors keep last usable plan; bounded retries; duplicate-tap protection

### Data/backend
- [x] F1 Documented schema with persistence/expiry per field
- [x] F2 Owner-scoped rules, schema validation, server-only state, indexes
- [x] F3 Callables authenticate, check ownership, validate, enforce limits, idempotent
- [x] F4 Persistent cache, pending/synced/failed states, journal for rejected writes, conflict policy
- [x] F5 Permissions at point of use; manual paths without camera/location

### Design/accessibility
- [ ] G1 DESIGN.md tokens/layouts/decisions; light/dark; Dynamic Type; VoiceOver; 44pt; reduced motion; non-colour status — *VoiceOver/Reduce Motion audit on a device outstanding*
- [x] G2 Every loading/empty/error/offline/permission state has a next action
- [x] G3 Simulator screenshots inspected on compact and large iPhones

### Acceptance scenarios (prompt §acceptance_examples)
- [x] E1 Toronto return + Victoria SHIP TO with UNIT 204 → recipient + unit preserved; synthetic not "deliverable"
- [x] E2 French EXPÉDITEUR/DESTINATAIRE, accents, APP. 12, Québec postal → preserved, review when uncertain
- [x] E3 Repeated tracking ID → one package + duplicate feedback; same destination → one stop/two packages; other unit distinct
- [x] E4 Unreadable civic + readable postal → unresolved; tracking-only barcode invents nothing
- [x] E5 Batch auto-add with Undo; ambiguous → review without blocking
- [x] E6 Offline delivered → terminate → reopen → sync once; late optimizer cannot undo
- [x] E7 Incompatible hard windows → infeasibility shown, packages retained, driver decides
- [x] E8 Edit during optimization → stale result rejected, edit preserved
- [ ] E9 Navigation app opens building address; same stop shown on return — *URLs verified; app round trip is a device check*
- [x] E10 Cross-user access denied (rules + callables); quota and missing config produce useful errors
- [ ] E11 10/50/200-stop timings, mocked vs live labelled; real-device gaps listed — *mocked timings recorded; live timings not measured*
