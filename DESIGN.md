# ParcelPilot — Atlas Focus

Approved target: [handoff](docs/redesign/atlas-focus/HANDOFF.md) and its eight mockups. Implementation
is confined to SwiftUI presentation. ParcelPilotKit, schema, Cloud Functions, rules, demo seed and the
app icon remain unchanged.

## Principles

The destination and delivery actions remain visible. Delivery retains fixed header, flexible map
and fixed bottom regions. Planning has a draggable stops-panel handle: drag up for the full list,
drag down to restore the map, or tap the handle to switch. Full list / Map remains available and
remembers the same scene preference. The footer stays visible in both positions, and scrolling
or reordering stops does not resize the panel. At accessibility text sizes planning keeps the full
list with no drag required; Reduce Motion disables the panel spring. Start delivering enters delivery; Back to
planning lives in the Stops sheet's route menu. Tabs remain Route, Scan, History and Settings, and
are hidden inside the workspace. Route Scan opens a full-screen scanner; the Scan tab remains.

Every uncertain address keeps separate text-recognition, completeness and map-match signals.
Estimates disclose source and calculation time. Outcomes require driver action, Failed requires a
reason, and navigation return only shows the return banner. Provider coordinates are shown only
on their permitted map provider; demo and emulator locations remain labelled synthetic.

## Tokens

Dynamic light/dark colours in `Theme.swift`; default appearance follows the system. No forced theme.

| Token | Light | Dark |
|---|---|---|
| brand | #4338CA | #9C97FF |
| onBrand | #FFFFFF | #0E0F12 |
| brandSoft | #ECEBFB | #24233F |
| success | #177A3F | #4CC97F |
| danger | #B42318 | #FF7B72 |
| dangerSoft | #FBE6E4 | #3A1E1E |
| warning | #9A5700 | #F2B04B |
| warningSoft | #FCF0DD | #3A2E17 |
| reviewPin | #B36500 | #F2B04B |
| neutral | #5A606C | #A4A9B2 |
| fill | #F1F2F5 | #22252C |
| panel | #FFFFFF | #17191E |
| hairline | #E3E5EA | #30343C |
| ink | #16181D | #F2F3F5 |
| pinPending | #16181D | #E6E8EC |
| demo | #7A3FD1 | #C3A1FF |

`teal` is retired. `surface` and `elevated` map to `panel`; `separator` maps to `hairline`.
Increased Contrast resolves hairline to #858A95 / #737986.

### Contrast verification — October 4, 2026

Computed with the WCAG sRGB linearization and relative-luminance formula
`(Llighter + 0.05) / (Ldarker + 0.05)`. Normal text requires 4.5:1; graphical boundaries require 3:1.

| Pair | Light | Dark |
|---|---:|---:|
| brand/onBrand | 7.90:1 | 7.56:1 |
| success/onBrand | 5.40:1 | 9.10:1 |
| danger/onBrand | 6.57:1 | 7.60:1 |
| warning/onBrand | 5.62:1 | 10.12:1 |
| brand/brandSoft | 6.71:1 | 5.97:1 |
| danger/dangerSoft | 5.49:1 | 6.02:1 |
| warning/warningSoft | 4.99:1 | 7.00:1 |
| neutral/panel | 6.32:1 | 7.45:1 |
| neutral/fill | 5.64:1 | 6.50:1 |
| ink/panel | 17.76:1 | 15.84:1 |
| pending/panel | 17.76:1 | 14.33:1 |
| reviewPin/panel (graphical ring only) | 4.39:1 | 9.28:1 |

White on the specified light reviewPin is below the normal-text threshold. Review badges therefore
use the pending high-contrast number surface with an amber ring. Amber is never the sole status
signal: list text, warning icon, review action and combined VoiceOver labels remain.

StatusBadge foreground on its 12% tinted panel (light / dark): brand 6.49 / 5.71,
success 4.57 / 6.74, danger 5.38 / 5.81, warning 4.75 / 7.37, neutral 5.34 / 6.06,
demo 5.08 / 6.64. Toast white on #16181D is 17.76:1. Semantic filled buttons use onBrand,
including dark-mode Delivered and failure reason selection.

### Type, spacing and controls

SF Dynamic Type styles: destination `.title` bold rounded; route name `.headline` bold rounded;
progress and sheet titles `.title3` bold rounded; unit `.title` heavy monospaced; vehicle code
`.title3` heavy monospaced; rows `.headline`; secondary `.subheadline`; section/provenance `.footnote`.
Spacing remains 4/8/12/16/24/32. Buttons and tiles use 14 pt radii, Delivered 16, panels 22.
Explicit secondary text uses the verified neutral token, including provenance and review checks.
Every interactive target is at least 44 pt; secondary actions 50, planning primary 52,
Delivered 58 (at least 72 at accessibility sizes).

## Screens and interaction

- Planning: route header with All routes, Find and route menu; numbered map, unaccepted order dashed,
  accepted order solid; review row; ordered list with Edit order; pinned Scan / Add / adaptive primary.
  No stops → Add stops. Unaccepted/stale → Optimize… (offline explanation). Accepted or kept order →
  Start delivering. Review stops do not block starting. No current-order travel metrics are invented.
- Delivering: progress, separate stop/package status, non-synced row, address/unit/window/note;
  flexible map and nearby-stop strip; selected pending packages; Navigate / Failed / Skip / Delivered.
  Deselecting a package gives a partial outcome and leaves it actionable. Inspecting a strip stop
  centres the map and opens Details without setting the next delivery. The real current stop keeps
  its larger brand badge and contrasting 3 pt ring; inspecting a pending stop preserves its pending
  colour and adds a selection outline. Badge numbers stay on one line.
- Stops: search address/unit/tracking/shelf, counts, failed/skipped decisions with Retry later/Exclude,
  ordered To do with NEXT, expandable Done, Re-plan remaining, explicit Finish route confirmation,
  route menu and All routes. Decisions use existing outcome/Undo operations.
- Optimization: Proposed/Current map, actual metrics, savings only from a computed baseline,
  excluded/unplaced reasons, position changes, equal-size Keep my order / Use this order buttons.
  Keep and Close leave domain order and outcomes untouched; only Use applies after validation.
- Review: map with always-visible Place pin, three checks, original text, persistent field captions
  and warning outlines, placement/duplicates/package fields; pinned Add to route or Save for review /
  Add with warning. Offline checks have an explicit disabled state.
- Scan: target-route menu, Batch switch, live framing/status, review bar, Import/Light/78 pt Shutter/Type.
  Permission and no-camera fallbacks remain. Batch adds retain their existing Undo.
- Stop detail: reused destination header, packages/edit/removal with inline Undo, window, notes,
  photos, Address & pin, Deliver next and Remove stop. Routes, History, Settings and sign-in use the
  shared tokens; Google branding, the native Apple sign-in control and account safeguards remain.

### Sign-in

The [approved sign-in mockup](docs/redesign/sign-in/approved-design.png) uses a compact left-aligned
ParcelPilot lockup, a separate route illustration, “Ready for your next route?” and two equal-width
authentication actions. The screen uses `panel` as its background, a 40 pt scalable headline, 28 pt
horizontal margins, 12 pt button radii and a 52 pt minimum button height. Google uses its official
multicolour mark and bundled Google Sans Medium; its border follows
[Google's branding guidelines](https://developers.google.com/identity/branding-guidelines).

The illustration has dedicated light/dark assets and is hidden at accessibility text sizes. The
content scrolls on small screens and at larger text sizes; buttons and text grow without truncating.
Sync reassurance sits below the buttons and account-deletion copy at the bottom. Loading, Google
configuration notices, signed-out notices, authentication errors, the email sheet, optional Apple
sign-in and the emulator-only account fixture preserve the existing authentication behavior.

## Accessibility and adaptation

FocusLayout measures header/packages/actions and collapses the map when less than 160 pt remains,
or whenever Dynamic Type is an accessibility size. Header and packages then scroll together, Show
map opens a full-screen map with Close, and a destination is pinned above the three-row action deck.
Planning uses list view at accessibility sizes; its summary/review/footer chrome caps at xxxLarge
and uses two footer rows to leave room for the growing stop list. Optimization choices stack at
accessibility sizes with equal widths and heights. Address, unit, package locations and Delivered grow;
secondary chrome caps at xxxLarge with Large Content Viewer where appropriate. The largest text
can stack the Delivered count below its label rather than wrap a word.

VoiceOver order is header → packages → actions → map/strip, using sort priorities. The map is one
summary element; strips and Stops provide labelled access to stops. Include buttons expose
isSelected and counts are spoken by Delivered. Undo announcements extend to 30 seconds under
VoiceOver. Swipe actions also have visible detail buttons. Map camera animation observes Reduce
Motion; there are no decorative workspace transitions. Bold Text uses system fonts.

Identifiers are preserved per handoff §13. Removed: workspaceMode, the old delivery panelHandle, Delivered's modal
package controls. Added: startDelivering, backToPlanning, stopsSheet, stopStrip.N, showMap,
planListToggle, planningPanelHandle, packageToggle.N, syncStateRow. UI tests assert saved addresses/order/counts/Undo.

## Evidence

Run `scripts/run-all-tests.sh`, `scripts/run-emulator-e2e.sh`, and `scripts/capture-screenshots.sh`.
The capture harness checks real controls and exports planning/map/list, delivery/partial, Stops,
optimization, address review, scan, history and settings on iPhone SE and iPhone 17 Pro Max in
light/dark at Large/AX3. See [the dated audit](docs/SIMULATOR_AUDIT_2026-10-04.md) for actual results
and remaining verification. Simulator screenshots do not establish physical-camera, full VoiceOver,
or live production-provider compliance.
