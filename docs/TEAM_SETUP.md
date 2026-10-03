# Team setup

How to get a working copy of ParcelPilot on a second developer's Mac and iPhone. The live project is
Firebase/Google Cloud project **`parcelpilot-976f6`** (alias `prod`), region `northamerica-northeast1`.
[COST_AND_SETUP.md](COST_AND_SETUP.md) describes how that project was built; you don't need to repeat it.

## 1. Without any accounts (start here)

Install the [requirements](../README.md#requirements), clone the repo, then follow README → "Run
locally": **demo mode** and the **local Firebase emulators** need no keys, no Firebase access and no
billing. All tests in README → "Tests" run this way.

## 2. Against the live project

Some files are deliberately not in git. Get them as described here; never commit them.

| File | What it holds | Where it comes from |
|---|---|---|
| `Config/Secrets.xcconfig` | Your Apple team, your bundle ID, the Maps key, the Google sign-in URL scheme | Copy `Config/Secrets.example.xcconfig` and fill in (below) |
| `ParcelPilot/GoogleService-Info.plist` | Firebase client config for **your** bundle ID | Firebase console (below) |

### Access (the project owner does this once)
1. **GitHub:** add you to the repo.
2. **Firebase:** Firebase console → Project settings → **Users and permissions** → Add member with
   your Google account. *Editor* is enough to deploy; *Viewer* if you only run the app.

### Your bundle ID
With a free Apple Personal Team, a bundle ID belongs to one Apple account, so each developer uses
their own, e.g. `ca.yourname.parcelpilot`. Then, in the console (or ask the owner):
1. Firebase → Project settings → **Add app → iOS** with your bundle ID → download its
   `GoogleService-Info.plist` into `ParcelPilot/`.
2. Google Cloud → APIs & Services → Credentials → **ParcelPilot iOS Maps** → iOS restrictions →
   add your bundle ID. (The key stays restricted to the Maps SDK for iOS.)

### `Config/Secrets.xcconfig`
```
PP_DEVELOPMENT_TEAM = <your Team ID — Xcode → Settings → Accounts, or developer.apple.com>
PP_BUNDLE_ID = <your bundle ID>
PP_APPLE_DEVELOPER_PROGRAM = NO
GOOGLE_MAPS_IOS_API_KEY = <Credentials → ParcelPilot iOS Maps → Show key>
GOOGLE_REVERSED_CLIENT_ID = <REVERSED_CLIENT_ID from your GoogleService-Info.plist>
```
The Maps key is client configuration (it ships inside the app and is protected by its bundle ID and
API restrictions), but still share it privately, not in chat logs or issues.

### Install on your iPhone
Plug the phone in, unlock it, enable Developer Mode (Settings → Privacy & Security), then:
```bash
scripts/install-on-device.sh
```
First launch: Settings → General → VPN & Device Management → trust your Apple ID. With a free team
the install expires after 7 days; run the script again.

## 3. Deploying the backend

```bash
cd firebase && npm ci && npm --prefix functions ci && npx firebase login
```
```bash
cd firebase && npx firebase deploy --only functions --project prod
```
- Function settings for production are in `firebase/functions/.env.parcelpilot-976f6` (committed: usage
  caps and the runtime service account, no secrets). Never put a secret in a `.env` file; use
  `firebase functions:secrets:set`.
- Rules and indexes: `--only firestore:rules,firestore:indexes,storage`.
- Deploy from an up-to-date `main` only, and tell the other person, so one deploy doesn't undo the
  other's changes.
- Paid Google APIs are reached only through the functions, which enforce the caps in
  [COST_AND_SETUP.md](COST_AND_SETUP.md) §1. Raising a cap raises the possible bill.

## 4. Working together

- Branch from `main`, open a pull request, merge when the tests in README → "Tests" pass.
- Don't commit `build/`, `Secrets.xcconfig`, `GoogleService-Info.plist` or anything under
  `node_modules/` (all git-ignored).
- [IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md) lists what's verified, what's blocked and
  what's left.
