# ParcelPilot design

Original visual system for a one-handed, in-vehicle tool. Apple's Human Interface Guidelines are the
primary reference for controls, accessibility and interaction; Spoke's public screenshots informed
*which tasks* drivers need (map + ordered list, next stop, quick outcomes) — not the look.

## Principles
1. **The route is the home screen.** Map on top, ordered stops or the next stop below.
2. **Delivery actions live in thumb reach.** Delivered is the largest, lowest control and is pinned
   to the bottom of the panel; it never scrolls away.
3. **Type as little as possible.** Scan, paste, import; quick-pick vehicle locations; one-tap outcomes.
4. **Say what is known, and how.** Recognition, completeness and map match are separate signals.
   Estimates show their source and calculation time. Demo data is labelled as synthetic everywhere.
5. **Nothing silent.** Every add, outcome and decision gives feedback and, where it changes data, an Undo.
6. **No decorative metrics.** Only what helps the next decision: duration, distance, finish time,
   packages left.

## Tokens (`ParcelPilot/DesignSystem/Theme.swift`)

### Colour (light / dark)
| Token | Light | Dark | Use |
|---|---|---|---|
| `brand` | #1F5AE0 | #6E9BFF | primary actions, stop markers, links |
| `teal` | #0B7A75 | #3CC8C1 | unit badge, secondary accent, start marker |
| `brandSoft` | #E8EFFD | #1B2A4A | secondary button fill, selected row |
| `success` | #1A7F37 | #4CC163 | delivered, verified |
| `danger` | #C62828 | #FF7B72 | failed, conflicts |
| `warning` | #9A5B00 | #F2B84B | needs review, skipped, outdated |
| `neutral` | #5B6472 | #A3ACBA | counts, excluded |
| `demo` | #7A3FD1 | #C3A1FF | demo/synthetic markers |
| surfaces | system grouped backgrounds | | |

Light-mode text colours meet WCAG AA (≥ 4.5:1) on white and on their 12 % tint backgrounds at the
sizes used; dark variants are lightened to keep contrast on dark surfaces. Status is always icon +
text (`StatusBadge`), never colour alone.

### Type
SF via Dynamic Type text styles only. Address on cards: `title2` semibold; list address: `headline`;
unit: `title3` bold monospaced digits in a teal badge; metrics: `headline` monospaced digits;
provenance: `caption` secondary.

### Spacing, shape, targets
Spacing 4 / 8 / 12 / 16 / 24 / 32. Radii 8 / 12 / 16 / 22 (panel). Minimum touch target 44 pt; primary
delivery action 56 pt; compact actions 52 pt.

### Motion and haptics
Spring panel transitions (disabled with Reduce Motion). Haptics: success (delivered, batch add),
warning (duplicate, sent to review, failure), selection (reorder, reason chips).

## Screens

### Route (tab 1)
```
┌ toolbar: [Routes]  Route name / "Demo · 11 stops · Planning"   [Find package] [⋯] ┐
│ MAP (Google in production / Apple MapKit for synthetic demo data)                  │
│   numbered markers (blue = to do, amber = partial/skipped, green ✓ = done), start ⌂ │
│   provider attribution always visible above the panel                               │
├──────────────── draggable panel: collapsed / half / full ───────────────────────────┤
│ [ Plan | Deliver ]                                              [sync indicator]    │
│ PLAN: summary row (Not optimized | Duration · Distance · Finish) [Optimize]         │
│       provenance line; warnings (start missing, review queue, needs review, offline)│
│       [Add stops] [Scan]                                    [Reorder]               │
│       1 ● 123 EXAMPLE ST  [Unit 204]  VICTORIA V8W 1A1  chips: 2 pkg · window · ETA  │
│ DELIVER: progress bar · "Back from navigation" banner · next-stop card (unit badge,  │
│       address, window semantics, notes, packages with vehicle location) · needs a    │
│       decision (Retry later / Exclude) · [Re-plan remaining]                         │
│       ── pinned action bar ── [Navigate] [Failed] [Skip] / [   Delivered   ]          │
└─────────────────────────────────────────────────────────────────────────────────────┘
```
Decisions: the map is laid out *above* the panel (not underneath it) so framing and attribution are
correct at every panel height; the panel handle has VoiceOver actions (Expand / Half / Collapse).
The medium panel takes 70 % of the available height, or 72 % at accessibility text sizes; short
screens get +8 %. Short screens and accessibility sizes start expanded. The handle is a 44 pt
button with tap, drag and VoiceOver resize actions. Deliver cannot collapse below medium height.
Its pinned action bar repeats the destination and unit, so both remain visible while reading notes
or reviewing earlier failures.

### Scan (tab 2)
Header: target route + **Batch** toggle (with plain explanation). Camera area: live scanner with a
dashed framing guide that turns solid green when an address is in view; status pill while reading /
checking; quality hints (blur, glare, dark). Bottom: Import · Light · **Shutter** · Type. Fallbacks
replace the camera area for not-determined / denied / restricted / unsupported / no-camera states,
each with a next action. Normal mode opens the confirmation card; batch mode shows Undo toasts and
sends uncertain labels to the review queue.

### Confirmation card (scan, manual, review)
Sections: choice (when several destinations) → **Checks** (Text recognition · Address completeness ·
Map match, each with a plain explanation) → label text beside the map result + per-field differences
→ editable fields (unit and type, number, street, PO box/RR, city, province, postal code with an
explicit "Use X instead of Y?" suggestion for OCR confusions) → reasons needing review (+ place a pin)
→ placement (existing stop / other unit in building / duplicate tracking) → package fields (tracking,
vehicle location quick picks, size, notes) → Save for review / Discard. **Add to route** is pinned
below the scrolling form; unresolved addresses use **Add with address warning**. Field captions
remain visible after typing, and confirmation waits for any address check already in progress.

### Optimize sheet
Options (start from route start / current location / a stop; fixed next stop; traffic-aware; compare
with current order) with footers explaining cost and privacy → "What gets planned" (counts + reasons for
excluded stops) → Calculate → progress (server runs asynchronously; safe to close) → preview: metrics,
savings only with a computed baseline, unassigned stops with suggestions, notes, changed positions →
**Use this order** / Keep my current order, pinned below the scrolling preview. Metrics adapt to
available width. Stale and failed states explain and offer Recalculate.

### History (tab 3) and Settings (tab 4)
History: finished/archived routes → summary with actual times from outcomes and distance with its
source (or why it isn't available). Settings: navigation app, units, default stop time, batch default;
account (sign out with unsynced warning, delete account after confirming it's you — password, Google
or Apple, matching how the account signs in); privacy explainer; sync status; configuration status.

### Sign-in
Google's official "Sign in with Google" button (Google's branding rules), **Continue with email**
(one sheet: Sign in / Create account, Forgot password), Sign in with Apple only in builds with the
paid Apple Developer Program, plus demo mode. Messages never reveal whether an email has an account.
New email accounts get a banner above the tabs — "Confirm your email" with **I've confirmed it** and
**Resend link** inline — until the address is confirmed; address checks and route planning wait for it.

## States checklist
| State | Where | Next action offered |
|---|---|---|
| Loading | routes, route, photos, optimizer | progress text; optimizer can be closed safely |
| Empty | no routes / no stops / no history / review queue empty | create route, load sample (demo), scan, add stops |
| Offline | banner, sync indicator, optimizer, verification | work continues; verification/optimization resume online |
| Permission | camera (not determined / denied / restricted), location | allow, open Settings, import photo, type, choose a stop/address |
| Error | optimizer, verification, navigation, sync rejects | retry, recalculate, edit constraints, Retry/Discard rejected writes |
| Not configured | Firebase plist, Maps key | demo mode; exact file/setting to add |

## Accessibility
Dynamic Type everywhere (no fixed font sizes for text); VoiceOver labels combine stop number,
address, unit, package count, status and ETA; outcome toasts are announced; selected chips expose
`.isSelected`; 44 pt targets; Reduce Motion respected; colour never the only signal.
Screenshots of light, dark and large-text states are produced by `scripts/capture-screenshots.sh`
(iPhone SE 3rd gen and iPhone 17 Pro Max × light/dark × Large/AX3). The harness waits for actual
screen controls through XCTest before accepting captures. See the dated simulator audit for the
inspected screenshots, workflow results and remaining device-only checks.

Rules for accessibility text sizes (`dynamicTypeSize.isAccessibilitySize`), from that review:
- Side-by-side title + button rows stack vertically (plan summary + Optimize, banner + action, Scan
  header + Batch); button titles never wrap mid-word (`lineLimit(1)` + `fixedSize`, or
  `ViewThatFits` to a wrapped layout).
- What the driver must read grows without limit: address, unit, package locations, Delivered.
  Chrome is capped: the map's "Demo map" badge (≤ xLarge), the Navigate/Failed/Skip bar (≤ xxxLarge,
  with the Large Content Viewer on long press, as system bars do), progress and "Stop N of M"
  (≤ xxxLarge).
- Explanatory text in fixed-height areas (camera permission/fallback) uses `FitOrScroll`: shown as
  is when it fits, otherwise scrollable — never truncated.
At AX3 and larger on iPhone SE, long stop cards, planning content and camera explanations require
scrolling. The delivery destination and action bar stay visible. On Simulator, camera-only controls
are disabled and Import / Type provide usable alternatives; physical-device permission handling,
torch and live scanning still require device testing. Screenshot inspection does not establish
VoiceOver or full accessibility compliance.
