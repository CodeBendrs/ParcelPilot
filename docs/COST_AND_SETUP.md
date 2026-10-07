# Cost and setup guide

The existing project **`parcelpilot-976f6` has a deployed backend**. On 2026-10-04, a read-only
Firebase CLI check confirmed all five functions ACTIVE in `northamerica-northeast1`, running
Node.js 22 with `PROVIDER_MODE=google` and callable **`ENFORCE_APP_CHECK=false`**. See
[IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md) for the evidence and verification limits.

The steps below describe initial setup and future configuration/deployments; they do not mean the
existing project is undeployed. Billing changes and deployments must be run deliberately.
The deployment audit did not inspect billing/spend or exercise paid Google API calls.
Prices were checked on 2026-10-03 against
https://developers.google.com/maps/billing-and-pricing/pricing (USD, per calendar month) — recheck
before launch.

## 1. What costs money

| Service | Used for | Free each month | Then (first tier) | ParcelPilot hard cap (default) |
|---|---|---|---|---|
| Route Optimization — Single Vehicle Routing | `requestOptimization` | 5,000 shipments | $10.00 / 1,000 shipments | 4,500 shipments/month project-wide (`MONTHLY_SHIPMENT_BUDGET`), 2,000/day/user, 25 optimizations/day/user |
| Geocoding API | `resolveAddress` | 10,000 requests | $5.00 / 1,000 | 9,000/month project-wide (`MONTHLY_GEOCODE_BUDGET`), 400/day/user |
| Places API (New) — Autocomplete Requests | `suggestAddresses` (suggestions while typing an address) | 10,000 requests | $2.83 / 1,000 | 9,000/month project-wide (`MONTHLY_SUGGESTION_BUDGET`), 500/day/user |
| Maps SDK for iOS | the in-app map | Unlimited (no charge for mobile map loads) | — | — |
| Firebase (Blaze plan required for Functions) | Auth, Firestore, Storage, Functions, App Check, Crashlytics | Generous free quotas | usage-based | — |

**How a shipment is counted:** one per stop sent to the optimizer. Pins and the fixed next stop do not
add shipments (prefix/suffix segments contain one stop each, and every stop is sent exactly once). The
optional "Compare with my current order" doubles the shipments for that request.
Requests that fail validation, run in `VALIDATE_ONLY`, or have infeasible/ignored shipments are not
billed (Google's billing page). ParcelPilot retries only transient 5xx errors where nothing was billed,
at most twice; timeouts are **not** retried because they may have been billed.

**Example:** one driver, 200 stops/day, 22 working days, optimizing twice a day:
200 × 2 × 22 = 8,800 shipments → 5,000 free + 3,800 × $0.01 = **≈ $38/month**. Address checks for
220 new addresses/day ≈ 4,840/month → free. Address suggestions are requested after a 350 ms pause in
typing (4+ characters), so a typed address costs a few requests; picking one costs one address check. With the default caps, optimizations stop at 4,500
shipments/month (inside the free tier) and the app shows "Monthly optimization limit reached".
Raise `MONTHLY_SHIPMENT_BUDGET` deliberately when you accept the cost.

**Caps vs alerts:** the counters above are enforced in Firestore transactions before each paid call —
they are hard limits. Google Cloud budget alerts only notify; they are not a spending cap. Set both.
You can also set per-API quotas (requests/minute/day) in Google Cloud Console → APIs & Services → Quotas
as a second hard limit.

## 2. Firebase project

1. Create a Firebase project (console.firebase.google.com). Note the project ID.
2. **Firestore**: create the database in **Native mode**, location `northamerica-northeast1` (Montréal).
3. **Storage**: create the default bucket in `northamerica-northeast1`.
4. **Authentication → Sign-in method**: enable **Apple**. (Anonymous auth is only used by the local emulator build; leave it disabled in production.)
5. **App Check**: register the iOS app with **App Attest** (DeviceCheck fallback). Enforce App Check for Firestore, Storage and Functions once a release build is verified. For Debug builds, copy the debug token printed in Xcode's console into App Check → Manage debug tokens.
6. **Crashlytics**: enable in the console.
7. Upgrade to the **Blaze** plan (required for 2nd-gen Functions and outbound calls). *This enables billing — only do it when you intend to deploy.*
8. Add an iOS app with your bundle ID, download `GoogleService-Info.plist`, and place it at `ParcelPilot/GoogleService-Info.plist` (git-ignored; the synchronized Xcode folder picks it up automatically).

## 3. Google Maps Platform (same Google Cloud project)

1. Enable **Route Optimization API**, **Geocoding API**, **Places API (New)** (address suggestions)
   and **Maps SDK for iOS**.
2. **Server access (no keys):** the functions call Route Optimization and Geocoding with their runtime
   service account (Application Default Credentials, OAuth scope `cloud-platform`). Create a dedicated
   service account, e.g. `parcelpilot-functions@PROJECT.iam.gserviceaccount.com`, grant it:
   - `roles/routeoptimization.editor` (Route Optimization `routeoptimization.locations.use`),
   - `roles/datastore.user`, `roles/storage.objectAdmin` (scoped to the default bucket if you prefer),
     `roles/firebaseauth.admin` (for `deleteAccount`),
   and put its email in `firebase/functions/.env.<projectId>` as `RUNTIME_SERVICE_ACCOUNT` — the functions
   then run as that identity (least privilege instead of the default compute service account).
   Never download a service-account key. No server secrets are needed; if you later add any, store them
   with `firebase functions:secrets:set` (Secret Manager) — never in code or `.env` files.
3. **Client key (public, restricted):** create an API key for the app's map only:
   - Application restriction: **iOS apps** → your bundle ID.
   - API restriction: **Maps SDK for iOS** only.
   Put it in `Config/Secrets.xcconfig` as `GOOGLE_MAPS_IOS_API_KEY`. This is client configuration, not
   a secret: it ships inside the app and is protected by its restrictions.
4. Create a **budget with alerts** in Billing (e.g. at $20/$50) — informational only.

## 4. Sign-in methods

Drivers sign in with **Google** or with an **email and password**. Sign in with Apple is built in but
switched off until you have a paid Apple Developer Program membership.

1. Firebase → Authentication → Sign-in method:
   - **Google → Enable** (choose a support email).
   - **Email/Password → Enable** (leave "Email link" off).
   - Leave **Anonymous** off — it's only used by the local emulator build.
2. **Download `GoogleService-Info.plist` after enabling Google** (only then does it contain
   `CLIENT_ID` and `REVERSED_CLIENT_ID`), and put it at `ParcelPilot/GoogleService-Info.plist`.
3. In `Config/Secrets.xcconfig`, set `GOOGLE_REVERSED_CLIENT_ID` to the plist's `REVERSED_CLIENT_ID`
   (it registers the URL scheme Google uses to return to the app). The sign-in screen says exactly
   what's missing if either value is absent.
4. Optional: Authentication → Templates → customise the verification and password-reset emails
   (sender name, your support address).
5. Email accounts must confirm their address before address checks and route optimization work; the
   app shows a banner with "Send the link again" and the server enforces it.

**Later, with a paid Apple Developer Program membership** (needed for the App Store anyway; Apple's
guideline 4.8 generally expects Sign in with Apple when Google sign-in is offered):
1. Apple Developer → Identifiers → your App ID → enable **Sign in with Apple** and **App Attest**.
2. Keys → + → **Sign in with Apple** key (note the Key ID, download the `.p8` once).
3. Firebase → Authentication → Apple → Enable, and under "OAuth code flow configuration" enter your
   Team ID, the Key ID and the private key (used to revoke the Apple sign-in on account deletion).
4. In `Config/Secrets.xcconfig` set `PP_APPLE_DEVELOPER_PROGRAM = YES`. This switches in
   `ParcelPilot/AppleServices.entitlements`, shows the Apple button and uses App Attest for App Check.

**App Check with a free personal team:** App Attest needs the paid membership and DeviceCheck needs a
key only a paid account can create, so release builds can't get App Check tokens yet. Debug builds use
the App Check debug provider (register the token printed in Xcode's console under App Check → Manage
debug tokens). Until you have the paid membership, deploy with `ENFORCE_APP_CHECK=false`; the
server-side quotas still apply.

The October 4 deployment check confirmed this disabled callable-enforcement setting in the live
project. It did not inspect Firestore or Storage enforcement, which are separate settings. Verify
that release builds obtain valid attestation tokens and development builds use registered debug
tokens before enabling enforcement; otherwise legitimate clients can be rejected. See
[Firebase's enforcement guide](https://firebase.google.com/docs/app-check/cloud-functions).

## 5. Deploy (only when you decide to)

```bash
cd firebase && npx firebase use --add          # choose your project, alias "prod"
```
Set function parameters in `firebase/functions/.env.<projectId>` (or answer the prompts on first deploy):
`ENFORCE_APP_CHECK=true` (`false` until you have the paid Apple Developer Program — see §4), `PROVIDER_MODE=google`, `MAX_ELIGIBLE_STOPS=200`, the daily/monthly caps, and
`RUNTIME_SERVICE_ACCOUNT=parcelpilot-functions@PROJECT.iam.gserviceaccount.com`.
```bash
cd firebase && npx firebase deploy --only firestore:rules,firestore:indexes,storage,functions --project prod
```
After the first deploy, confirm the TTL policy on `optimizationRequests.expiresAt` is **Active**
(Firestore → TTL) and that `purgeExpiredProviderContent` is scheduled (Cloud Scheduler — small cost).

## 6. Regions and data location

| Data / processing | Location |
|---|---|
| Firestore, Cloud Storage, Cloud Functions | `northamerica-northeast1` (Montréal, Canada) |
| Firebase Authentication, App Check, Crashlytics | Google global infrastructure |
| Geocoding API, Route Optimization API | Google Maps Platform global endpoints — requests may be processed outside Canada |
| On-device OCR (Vision/VisionKit) | The iPhone only |

Canadian users do not imply that every vendor processes all data in Canada; the app's privacy screen
says so plainly.

## 7. Local development (no billing, no credentials)

See README → "Run locally". The Emulator Suite uses the `demo-parcelpilot` project, which cannot reach
real Google services, and the functions use the clearly labelled **emulator test provider** (synthetic
results). `PROVIDER_MODE=emulator-fake` is refused outside the emulator.
