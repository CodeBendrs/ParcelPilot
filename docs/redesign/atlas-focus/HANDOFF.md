# ParcelPilot UI redesign — "Atlas Focus" build handoff

**Audience:** the engineer or coding agent building the new UI.
**Status:** approved design direction, ready for implementation (October 4, 2026).
**Scope:** SwiftUI presentation layer only. Domain logic, data model, sync, Cloud Functions and
security rules do not change.

Read this whole document before writing code. The mockups in [`mockups/`](mockups/) are the
visual target; the text below is the contract when the two disagree. Exact pixel values for each
mockup are in [`mockups/source/`](mockups/source/) (static HTML; open in a browser or read the
inline styles).

---

## 1. What we are building

ParcelPilot keeps its existing capabilities and safeguards but gets a new layout called **Atlas
Focus**: inside an open route, the screen is three fixed regions with **no draggable panel**.

```
┌──────────────────────────────┐
│ HEADER (pinned)              │  Planning: route name, Find, menu
│                              │  Delivering: stop progress, offline state,
│                              │  ADDRESS + UNIT, note
├──────────────────────────────┤
│ MAP (flexible)               │  Fills remaining space. Collapses to a
│                       ┌────┐ │  "Show map" button when space is short.
│                       │strip│ │  Delivering: nearby-stops strip on the right.
├──────────────────────────────┤
│ BOTTOM PANEL (pinned)        │  Planning: review alert, stop list, Scan/Add/primary
│                              │  Delivering: packages + Navigate/Failed/Skip/Delivered
└──────────────────────────────┘
```

Why: the destination and the delivery actions can never scroll or drag out of view, and the map
keeps spatial context. The current `MapSheetLayout` (three detents, drag handle) is removed.

Default appearance is **light**; dark follows the system setting using the dark tokens in §4.

### Out of scope (do not add)
Fleet dashboards, customer tracking, subscriptions, social features, in-app turn-by-turn
navigation, new third-party dependencies, changes to `Packages/ParcelPilotKit`, Firestore schema,
Cloud Functions or rules.

---

## 2. Mockups

All mockups are 390 × 844 pt (iPhone 15/16/17 class), rendered at 2×. The status bar is omitted.
Content uses a fictional route ("Fernwood – Tuesday", Victoria BC, 14 stops / 21 packages); it is
illustrative only — do **not** change `DemoSeed`.

| # | File | Screen | Key points |
|---|---|---|---|
| 01 | [H01-Plan-Map.png](mockups/H01-Plan-Map.png) | Planning — map view | Header; map with numbered pins; review alert; first rows of ordered list; Scan / Add / **Optimize…** |
| 02 | [H02-Plan-List.png](mockups/H02-Plan-List.png) | Planning — list view | Same route, map hidden; plan status line; full ordered list; same footer |
| 03 | [H03-Delivering.png](mockups/H03-Delivering.png) | Delivering | Header with progress, offline row, address, unit tile, note; map with route to stop; nearby-stops strip; package tiles; action deck |
| 04 | [H04-Delivering-AX.png](mockups/H04-Delivering-AX.png) | Delivering — 4 packages at accessibility text size | Map collapsed to **Show map**; package rows instead of tiles; one package deselected → **Delivered · 3 of 4**; destination line pinned above actions; actions in 3 rows |
| 05 | [H05-Scan.png](mockups/H05-Scan.png) | Scan (batch mode) | Target route; Batch switch; framing guide; batch confirmation with **Undo**; review-queue bar; Import / Light / Shutter / Type |
| 06 | [H06-Address-Review.png](mockups/H06-Address-Review.png) | Address review (uncertain scan) | Map + pin + **Place pin**; three separate checks; label text; editable fields with the missing field highlighted; **Save for review** / **Add with warning** |
| 07 | [H07-Optimize-Preview.png](mockups/H07-Optimize-Preview.png) | Optimization preview | Proposed vs Current toggle on map; metrics with deltas; estimate source; unplaced-stop notice; changed positions; **Keep my order** and **Use this order** at equal size |
| 08 | [H08-Stops-Sheet.png](mockups/H08-Stops-Sheet.png) | Stops sheet (during delivery) + Undo toast | Search; counts; **Needs a decision** (Retry later / Exclude); To do with NEXT marker; Re-plan remaining; Finish route… |
| — | [ref-dark-planning.png](mockups/ref-dark-planning.png), [ref-dark-delivering.png](mockups/ref-dark-delivering.png) | Dark palette reference | **Colours only.** Layout is superseded by 01 and 03 (older strip and offline placement). |

---

## 3. Navigation and information architecture

| Level | What the driver sees | Tab bar |
|---|---|---|
| Routes list (`RouteTab` with no current route) | Routes, New route | Visible |
| Route workspace (`RouteWorkspaceView`) | Planning or Delivering for one route | **Hidden** (`.toolbar(.hidden, for: .tabBar)`) |
| Scan, History, Settings tabs | As today, restyled | Visible |

- Tabs stay: **Route, Scan, History, Settings** (`AppTab` unchanged; keep `tab.route` etc.).
- In the workspace, the back chevron (`allRoutes`) returns to the Routes list, which shows the tab bar again.
- **Scan** inside the workspace opens the scanner as a full-screen cover targeting the current route. The Scan tab stays for scanning to any route.
- The Plan/Deliver segmented picker (`workspaceMode`) is removed. The mode is:
  - Planning until the driver taps **Start delivering**, or the route is already active (`route.status == .active`, as `effectiveMode` already works today).
  - **Back to planning** is in the Stops sheet footer menu and the route menu (⋯).
  - Keep the `-PPInitialMode deliver|plan` launch argument working for UI tests and screenshots.
- Sheets presented from the workspace stay as today (`WorkspaceSheet`): add stops, optimize, stop detail, route settings, finder, review queue, manual/paste/CSV. Add a `.stops` case for the new Stops sheet.

---

## 4. Design tokens

Update `ParcelPilot/DesignSystem/Theme.swift`. Keep existing token **names** where a mapping exists so
call sites keep compiling; change their values. Add the new tokens.

### Colour

| Token (Swift) | Light | Dark | Use |
|---|---|---|---|
| `brand` *(value change)* | `#4338CA` | `#9C97FF` | Accent: primary buttons, current stop, unit tile, links |
| `onBrand` *(new)* | `#FFFFFF` | `#0E0F12` | Text/icons on `brand`, `success`, `danger`, `warning` fills |
| `brandSoft` *(value change)* | `#ECEBFB` | `#24233F` | Navigate button fill, NEXT badge, Retry later |
| `success` | `#177A3F` | `#4CC97F` | Delivered button, delivered status |
| `danger` | `#B42318` | `#FF7B72` | Failed, conflicts, map "building not found" |
| `dangerSoft` *(new)* | `#FBE6E4` | `#3A1E1E` | Failed button fill |
| `warning` | `#9A5700` | `#F2B04B` | Needs review, offline, skipped, partial |
| `warningSoft` *(new)* | `#FCF0DD` | `#3A2E17` | Warning callouts |
| `reviewPin` *(new)* | `#B36500` | `#F2B04B` | Map pin / badge for stops needing review |
| `neutral` | `#5A606C` | `#A4A9B2` | Secondary text, counts |
| `fill` *(new)* | `#F1F2F5` | `#22252C` | Secondary buttons, package tiles, search field |
| `panel` *(new)* | `#FFFFFF` | `#17191E` | Header, bottom panel, sheets |
| `hairline` *(new)* | `#E3E5EA` | `#30343C` | Dividers, panel borders |
| `ink` *(new)* | `#16181D` | `#F2F3F5` | Primary text; pending map pins (light) |
| `pinPending` *(new)* | `#16181D` on `#FFFFFF` ring | `#E6E8EC` on `#17191E` ring | Pending stop pins/chips |
| `demo` | unchanged | unchanged | Demo/synthetic markers (still used with `-PPDemoMode`) |
| `teal` | **retire** | | The unit badge now uses `brand` |

Requirements: text pairs must meet WCAG AA (4.5:1 normal text, 3:1 for ≥ 24 pt bold or ≥ 18.66 pt bold). Verify each pair with a contrast tool before merging and record the results in `DESIGN.md`. Status is never colour alone: always icon + text (keep `StatusTone` and the existing `symbol` mappings).

### Type (Dynamic Type styles only — no fixed font sizes)

| Role | Style | Mockup size at default |
|---|---|---|
| Destination address | `.title`, bold, `design: .rounded` | 30 |
| Stop progress ("Stop 6 of 14"), sheet titles | `.title3`, bold, rounded | 20–24 |
| Route name in header | `.headline`, bold, rounded | 19 |
| Unit value | `.title`, heavy, `design: .monospaced` | 28 |
| Vehicle location code (B2, FL) | `.title3`, heavy, monospaced | 20 |
| List address / package location | `.headline` (17 semibold) | 17 |
| Secondary lines, status line | `.subheadline` | 15 |
| Section headers | `.footnote`, bold, uppercase, +0.4 tracking | 13 |
| Captions (estimate source) | `.footnote` | 13 |

Replace `Font.address`, `Font.unit` in `Theme.swift` accordingly; add `Font.locationCode`, `Font.stopProgress`.

### Spacing, shape, targets
Spacing scale unchanged (4/8/12/16/24/32). Radii: buttons 14, Delivered 16, tiles 14, chips 7–12,
panels 22 (top corners of bottom panel, bottom corners of delivering header).

| Control | Min height |
|---|---|
| Any interactive element | 44 pt |
| Secondary actions (Navigate, Failed, Skip, Scan, Add) | 50 pt |
| Primary planning button (Optimize… / Start delivering) | 52 pt |
| **Delivered** | 58 pt (72 pt at accessibility sizes) |

Motion: no decorative animation. Map camera moves and sheet transitions respect Reduce Motion (cut instead of animate).

---

## 5. Components to build

Put shared pieces in `ParcelPilot/DesignSystem/Components.swift` (or a new `FocusComponents.swift`).

| Component | Purpose | Notes |
|---|---|---|
| `FocusLayout<Header, MapContent, Bottom>` | The three-region workspace layout | Replaces `MapSheetLayout`. Map gets the remaining height. Exposes `mapCollapsed: Bool` (see §8). Map attribution must stay visible: pass the header/bottom insets into the map's padding (`bottomInset` already exists on `RouteMapView`). |
| `UnitTile` | "UNIT 204" block | `brand` fill, `onBrand` text; caption "UNIT" + monospaced value; hides when stop has no unit. VoiceOver: "Unit 204". |
| `LocationCodeTile` | "B2" vehicle-location code | `fill` background, monospaced heavy. Derive code from the package's vehicle location (first letters/numbers); show full text beside it. |
| `StopBadge` | Numbered circle used in lists, pins, strip | States: pending, current (brand + 3 pt ring), delivered (✓ success), failed (✕ danger), skipped (↷ warning), partial (half-filled warning), needs review (reviewPin), excluded (dashed neutral). |
| `StatusLine` | "✓ 4 delivered  ✕ 1 failed · 6 of 21 packages" | Stop counts and package counts are separate. Skipped count appears when > 0. |
| `SyncStateRow` | Offline / syncing / rejected | Driven by the same source as `SyncStatusIndicator`. Tap opens `SyncStatusView`. Hidden when fully synced. |
| `StopStrip` | Nearby-stops strip on the delivering map | See §7.2. |
| `PackageSelectionList` | Tiles (≤ 2 packages, non-AX) or rows (> 2 or AX) with include toggles | See §7.3. |
| `ActionDeck` | Navigate / Failed / Skip / Delivered | Replaces `DeliveryActionBar` (keep its identifiers). |
| `ReviewAlertRow` | Amber outlined row with **Review** | Planning bottom panel; count variant "3 addresses need review". |
| `UndoToast` | Existing `ToastCenter` | Restyle: dark `ink` surface, white text, **Undo** button 44 pt. Position above the bottom panel; never covers the Delivered button. |

---

## 6. Planning (mockups 01, 02)

**File:** `Features/Workspace/RouteWorkspaceView.swift` (`PlanPanel`, `PlanSummaryCard`, `PlanWarnings`, `StopRow`).

### Header (both views)
- Back chevron `allRoutes` → Routes list.
- Route name (one line, truncates) + "Planning · 14 stops · 21 packages". Demo routes keep the demo marker.
- **Find** (`findPackage`) — labelled button, opens `PackageFinderView`.
- ⋯ (`routeMenu`): Route settings, Rename, Duplicate, Archive, **Start delivering** (always available), Re-optimize (when a plan exists).

### Map view (01)
- Map shows numbered pins in the current order with a dashed polyline (unoptimized) or solid (accepted plan); start marker; review stops in `reviewPin`.
- "Show whole route" button (bottom-right of map, 44 pt).
- Tapping a pin selects the stop: the list scrolls to it and the row highlights (existing `selectedStopID` behaviour).
- Bottom panel:
  1. `ReviewAlertRow` when any stop needs review (`reviewQueueBanner` id moves here). Shows the first address and the reason; count when > 1.
  2. Section header "STOPS · YOUR ORDER" with **Edit order** (`reorder`) and **Full list** (switches to list view).
  3. Ordered stop rows (scrollable inside the panel): badge, address (+ unit), package count with box icon, needs-review line, delivery window when set. Row tap → stop detail (`stopRow.N`).
  4. Footer: **Scan**, **Add** (`addStops`), adaptive primary (below).

### List view (02)
- Map hidden; list fills the space between header and footer. **Map** button returns to map view. Remember the choice with `@SceneStorage`.
- Plan status line above the review row: "Not optimized · Your order · 2 h 05 min · 38 km (estimate)"; after acceptance: "Optimized · 1 h 40 min · 31 km · finish 1:25 pm"; stale: amber "Order changed since optimizing — times outdated" + **Re-optimize**.
- Estimate source must always be shown (straight-line demo estimate vs road travel estimate), as today.

### Adaptive primary button (footer, right, `brand` fill)
| Route state | Primary | Notes |
|---|---|---|
| No stops | **Add stops** | Scan stays beside it |
| Stops, no accepted/kept order, or plan stale | **Optimize…** (`optimize`) | Offline: disabled with caption "Optimizing needs a connection" |
| Order accepted or driver chose **Keep my order** | **Start delivering** (`startDelivering`, new) | Switches to Delivering; route becomes active on first outcome as today |

Stops needing review never block **Start delivering**; they stay flagged in the list and the strip.

Reorder: keep the visible **Edit order** mode with drag handles (`reorder` → Done). Destructive swipe "Remove" must also be reachable as a button in stop detail, with the existing Undo.

---

## 7. Delivering (mockups 03, 04, 08)

**Files:** `Features/Deliver/DeliveryPanel.swift` (split it), `Features/Workspace/RouteWorkspaceView.swift`, `Features/Map/RouteMapView.swift`.

| Old component | New home |
|---|---|
| `ProgressHeader` | `StatusLine` in the delivering header |
| `NextStopInfo` | Delivering header (address `nextStopAddress`, unit, window, note) |
| `DeliveryActionBar` | `ActionDeck` in the bottom panel (keep `navigate`, `failed`, `skip`, `delivered`, `actionDestination`) |
| `NeedsDecisionSection` | Stops sheet → **Needs a decision** |
| Re-plan remaining / Finish early | Stops sheet footer |
| `returnBanner` | Bottom panel, above packages |
| `AllDoneCard` | Replaces packages + deck when all stops are handled (`finishRoute`) |
| `PackageOutcomeSheet` | Replaced for Delivered by inline selection; keep for package-level Failed if needed |
| `FailureReasonSheet`, `ReasonGrid` | Unchanged (restyle only) |

### 7.1 Header (pinned)
Row 1: "Stop 6 of 14" · Find (icon button, `findPackage`) · **Stops** (opens Stops sheet, `stopsSheet`).
Row 2: `StatusLine`.
Row 3: `SyncStateRow` ("Offline · 2 outcomes waiting to sync") — only when not fully synced.
Divider.
Address (`nextStopAddress`, tappable → stop detail) + `UnitTile`; city/postal + delivery window state ("open to 3 pm", "opens 12:00 pm", "window passed" — reuse current window semantics); note line with icon (one line, truncates; full text in detail).

### 7.2 Map + StopStrip
- Map frames the driver's location, the current stop (large brand pin with ring) and the next 2 stops (dashed). Delivered pins show ✓, failed ✕, skipped ↷.
- "Centre on my location" button bottom-left, attribution bottom-left above it — both clear of the strip.
- `StopStrip` (right edge, `stopStrip`): a **window** of stops around the current one — 2 before, current, then as many after as fit (at least 2) — labelled with the range ("4–8"), plus **All** (opens the Stops sheet). Chips: 44 pt targets, 32 pt visual. Tapping a chip centres the map on that stop and shows a callout with address and **Details**; it does **not** change the next stop. VoiceOver label: "Stop 5, delivered, 1587 Begbie St".
- The strip is hidden when the map is collapsed.

### 7.3 Bottom panel: packages + actions
- Header: "2 PACKAGES · IN YOUR VEHICLE" (or "4 PACKAGES · 3 SELECTED").
- Every pending package at the stop is **selected by default**. Each has an include toggle (`packageToggle.N`) that exposes the `.isSelected` accessibility trait.
- Layout: two side-by-side tiles when the stop has ≤ 2 pending packages and text is not an accessibility size; otherwise rows (mockup 04). Each shows location code, location text, size and the last 4 tracking digits.
- **Delivered** label: "Delivered · 2 packages" when all are selected; "Delivered · 3 of 4" when partial; disabled with the hint "Select a package" when none.
  - Partial delivery records Delivered for the selected packages; the others stay pending at the stop, the stop becomes **partial**, and the remaining packages stay on screen for Failed / Skip / Retry later.
  - Show an Undo toast: "Delivered 3 of 4 at 1300 Gladstone Ave".
- **Failed** opens the failure reason sheet for the selected packages (reason required; Cancel records nothing).
- **Skip** keeps today's semantics. Undo toast: "Skipped 1745 Rockland Ave · Undo".
- **Navigate** offers Apple Maps / Google Maps as today (`navigationAppPicker`) and hands off driver-placed coordinates when present. **Returning from navigation never records an outcome**; show `returnBanner` instead.

### 7.4 Stops sheet (mockup 08)
Large-detent sheet (`stopsSheet`), **Done** to close.
- Search field: address, unit, tracking or shelf. Results open the stop.
- Counts: "9 to do · ✓ 4 delivered · ✕ 1 failed" (+ skipped when > 0).
- **Needs a decision**: failed/skipped stops with **Retry later** and **Exclude** (existing semantics, each with Undo).
- **To do**: ordered remaining stops, the current one marked NEXT. Row tap → stop detail. "Deliver next" is a button in stop detail, not swipe-only.
- **Done**: collapsed group, expandable.
- Footer: **Re-plan remaining** (opens optimize with current location origin), **Finish route…** (existing confirmation), and **Back to planning** in a ⋯ menu.

---

## 8. Small screens and large text (mockup 04)

`FocusLayout` collapses the map when either is true:
- `dynamicTypeSize.isAccessibilitySize`, or
- the height left for the map is below 160 pt (e.g. iPhone SE with long content).

When collapsed:
- A **Show map** button (`showMap`) sits beside the unit tile. It opens a full-screen map sheet with the route, pins and **Close**.
- The header no longer pins. Header + packages scroll together.
- A one-line destination ("1300 Gladstone Ave · Unit 3B") is pinned above the action deck, so the destination is always visible (`actionDestination`).
- Action deck becomes three rows: Navigate (full width), Failed + Skip, Delivered (72 pt).
- The strip is hidden. **Stops** stays in the header row.

Growth rules (from `DESIGN.md`, still valid):
- Address, unit, package locations and Delivered grow without limit.
- Chrome (status line, strip labels, Navigate/Failed/Skip labels) caps at `.xxxLarge` and uses the Large Content Viewer on long press.
- Buttons never wrap mid-word. Rows stack vertically at accessibility sizes.

Planning at accessibility sizes opens in list view.

---

## 9. Other screens

### Scan (mockup 05) — `Features/Scan/ScanTab.swift`
- Header: Close (when presented from a route), "Scan labels", target route switcher ("Adding to Fernwood – Tuesday ⌄"), **Batch** switch (`batchToggle`) with its existing explanation in the switch's accessibility hint.
- Camera area: framing guide turns solid `success` when an address is in view. Status pill text reflects state: "Reading label…", "Address in view · hold still", "Checking map…".
- Batch mode: confirmation toast with **Undo** for each add ("Added 1120 Fort St · Unit 204 — 2nd package at this stop"). Uncertain labels go to the review queue.
- Review-queue bar (`reviewQueue`): "12 added · 1 to review ›".
- Controls: Import (`importPhoto`), Light, Shutter (`shutter`, 78 pt), Type (`typeAddress`).
- All existing camera permission/unavailable fallbacks stay, restyled.

### Address review / confirmation (mockup 06) — `Features/AddStops/AddressConfirmationView.swift`
- Nav: Cancel, "Review address" (or "Confirm label" when the address is clear).
- Map strip at the top with the matched pin and a match-quality callout ("Street match only"). **Place pin** (`placeStopPin`) is always visible here.
- **Checks**: three separate rows (keep `SignalRow`): Text recognition, Address completeness, Map match — each with icon, value and a plain explanation. Never merge them into one "verified" badge.
- **On the label**: the recognised text with unreadable parts marked.
- Editable fields with persistent captions (`field.unit`, `field.civic`, `field.street`, `field.postal`, …). The field causing the problem gets a warning outline and caption colour. Keep the OCR suggestion ("Use 204 instead of 2O4?").
- Placement, duplicates and package fields follow the fields, unchanged in behaviour.
- Pinned footer:
  - Resolved → **Add to route** (`addToRoute`).
  - Unresolved → **Add with warning** (same `addToRoute` id) + **Save for review**, with a one-line reason above ("Add a unit or place the pin to clear the warning").

### Optimization preview (mockup 07) — `Features/Optimize/OptimizeSheet.swift` (`ProposalPreview`)
- Options and progress screens: restyle only.
- Preview:
  - Map with a **Proposed / Current** toggle. The proposed route is solid `brand` with renumbered pins; the current route is dashed neutral. Add an overlay mode to `RouteMapView` or a dedicated preview map.
  - Metrics: duration, distance, finish time. Show deltas **only when a computed baseline exists** (existing rule).
  - Estimate source line ("Road travel estimate · calculated 8:02 am · not a guarantee"; demo: straight-line).
  - Unplaced/excluded stops callout with reasons.
  - "N STOPS CHANGE POSITION" list (old → new).
  - Pinned footer: "Nothing changes until you choose." + **Keep my order** (`keepCurrentOrder`) and **Use this order** (`applyPlan`) at **equal width and height**. Close cancels without changes.
  - Stale/failed states keep **Recalculate**.

### Stop details — `Features/Stops/StopDetailView.swift`
Reuse the delivering header (address, unit tile, window, note) at the top. Then sections: Packages (edit, vehicle-location quick picks, remove with inline Undo), Delivery window, Notes, Photos (proof of delivery), Address & pin (`editStopAddress`, `placeStopPin`), and actions **Deliver next** and **Remove stop** (with Undo). Behaviour unchanged.

### Routes list, History, Settings, Sign-in
Restyle only, with the new tokens and type:
- **Routes list:** large title, route rows with status icon + text (Planning / Active / Finished), New route (`newRoute`).
- **History:** list (`historyRow`) → summary with actual outcome counts, measured times and distance source.
- **Settings:** grouped list, unchanged content (navigation app, units, default stop time, batch default, account, privacy, sync status, configuration).
- **Sign-in:** keep Google's official button rules, Continue with email, Sign in with Apple behind its setting. No demo button.

---

## 10. States that must stay understandable

| State | Where | What the driver sees / can do |
|---|---|---|
| Offline | Delivering header `SyncStateRow`; planning header subtitle | "Offline · N outcomes waiting to sync" → `SyncStatusView` list. Recording outcomes works offline. Optimize and address checks are disabled with "Needs a connection". |
| Syncing | Same row | "Syncing N…" (neutral) |
| Sync rejected | Same row, `danger` | "1 change couldn't sync · Review" → existing Retry/Discard |
| Needs review | Planning review row, list rows, map pins, strip | **Review** opens address review |
| Stale plan | Planning status line | "Order changed since optimizing — times outdated" + **Re-optimize** |
| Back from navigation | Delivering bottom panel | `returnBanner`; no automatic outcome |
| Partial stop | Strip chip, list row, pin | Half-filled badge + "1 of 2 delivered" |
| All handled | Delivering bottom panel | `AllDoneCard` + **Finish route** |
| Empty route | Planning | Empty state with **Scan** and **Add stops** |
| Camera unavailable/denied | Scan | Existing fallbacks with next action |

---

## 11. Safeguards and behaviour to preserve (regression list)

1. Optimization proposals are never applied without **Use this order**; **Keep my order** and Close change nothing.
2. Returning from Apple/Google Maps never marks anything delivered.
3. Failed requires a reason; cancelling records nothing.
4. Undo exists for: delivered, failed, skipped, retry later, exclude, stop removal, package removal and batch scan adds.
5. Finish early requires an explicit choice.
6. Text recognition, address completeness and map match stay separate signals.
7. Driver-placed pins take precedence over typed addresses for navigation.
8. Stop counts and package counts are always shown separately.
9. Offline outcomes survive termination and relaunch; nothing in the UI implies they were uploaded before they were.
10. Demo/synthetic data stays labelled when `-PPDemoMode YES` is used.
11. Account deletion and sign-out keep their confirmations and unsynced-data warning.

---

## 12. Accessibility requirements

- VoiceOver reading order in Delivering: stop progress → status → sync state → address → unit → window → note → packages → actions. The strip and the map come after the actions.
- The map is one element with a summary label ("Route map, 14 stops, current stop 6"); pins are reachable via the Stops sheet and the strip.
- Combined labels: stop rows announce number, address, unit, package count, status and window.
- Include toggles expose `.isSelected`. Delivered announces its count ("Delivered, 3 of 4 packages").
- Toasts are announced (`AccessibilityNotification.Announcement`) and Undo is reachable by VoiceOver before the toast dismisses (extend the timeout while VoiceOver is running).
- Every icon-only button has a label (Find, Centre on my location, Show whole route, ⋯).
- No gesture-only actions: everything swipeable also has a visible button.
- Reduce Motion, Bold Text, Increase Contrast (use the `ink`/`hairline` tokens; consider darker `hairline` when contrast is increased).

---

## 13. Accessibility identifiers

Keep every existing identifier that still has a matching control (see `grep -r accessibilityIdentifier ParcelPilot`), including `allRoutes`, `routeMenu`, `findPackage`, `optimize`, `applyPlan`, `keepCurrentOrder`, `calculate`, `addStops`, `reorder`, `stopRow.N`, `nextStopAddress`, `actionDestination`, `navigate`, `failed`, `skip`, `delivered`, `returnBanner`, `finishRoute`, `reviewQueueBanner`, `saveFailure`, `reason.*`, `addToRoute`, `placeStopPin`, `field.*`, `batchToggle`, `shutter`, `importPhoto`, `typeAddress`, `reviewQueue`, `syncStatus`.

| Removed | Replacement |
|---|---|
| `workspaceMode` | `startDelivering` (planning footer / route menu), `backToPlanning` (Stops sheet menu / route menu) |
| `panelHandle` | none (no draggable panel) |
| `outcomePackage.N` / `savePackageOutcome` (Delivered path) | `packageToggle.N` + `delivered` |

New: `stopsSheet`, `stopStrip`, `stopStrip.N`, `showMap`, `planListToggle`, `syncStateRow`.

Update `ParcelPilotUITests/DriverFlowUITests.swift` and `EmulatorEndToEndUITests.swift` accordingly. Keep their assertions on real outcomes (saved addresses, order, package counts, Undo results); don't weaken them.

---

## 14. Implementation plan

Work in this order. After each phase, build, run tests and compare screenshots with the mockups.

1. **Tokens and components.** `Theme.swift` values + new tokens; fonts; `UnitTile`, `LocationCodeTile`, `StopBadge`, `StatusLine`, `SyncStateRow`, button styles (`PrimaryButtonStyle`, `SecondaryButtonStyle`, new `ActionButtonStyle`). Update map marker images (`MarkerIcon.image(number:status:selected:)`) for the new pin states.
2. **FocusLayout + Delivering.** New `FocusLayout`; hide the tab bar in the workspace; split `DeliveryPanel` into header / package selection / `ActionDeck`; `StopStrip`; Stops sheet; collapsed-map rules (§8). Delete `MapSheetLayout`/`SheetDetent` once unused.
3. **Planning.** Map/List views, `ReviewAlertRow`, adaptive primary, **Start delivering**, removal of the mode picker; route menu additions.
4. **Optimization preview.** Proposed/Current map overlay, metrics, equal-weight footer.
5. **Address review and Scan.** Restyle `AddressConfirmationView`, `ScanTab`/`ScanScreen`, `ReviewQueueView`.
6. **Remaining screens.** Stop detail, Routes list, History, Settings, Sign-in.
7. **Docs and evidence.** Update `DESIGN.md` (tokens, screens, rules), refresh screenshots with `scripts/capture-screenshots.sh`, and add a dated audit note like `docs/SIMULATOR_AUDIT_2026-10-04.md`.

Commands:
```bash
xcodebuild -project ParcelPilot.xcodeproj -scheme ParcelPilot -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData.noindex build CODE_SIGNING_ALLOWED=NO
```
```bash
scripts/run-all-tests.sh
```
```bash
scripts/capture-screenshots.sh
```

---

## 15. Acceptance criteria

Verify on iPhone SE (3rd gen) and iPhone 17 Pro Max, light and dark, at Large and AX3 text sizes.

- [ ] In Delivering, the address, unit and Delivered button are visible at all times, at every size tested.
- [ ] No draggable panel remains; every region is reachable without gestures.
- [ ] Map attribution is visible in every map state.
- [ ] Touch targets ≥ 44 pt; Delivered ≥ 58 pt (72 at AX sizes).
- [ ] Colour pairs verified at WCAG AA, recorded in `DESIGN.md`.
- [ ] All items in §11 still hold (covered by UI tests where they exist today).
- [ ] Scenario 1: scan an uncertain label → review shows three separate checks → fix unit or place pin → added, or saved for review.
- [ ] Scenario 2: Unit 204 with two packages → deselect one → "Delivered · 1 of 2" → stop shows partial, the remaining package still actionable.
- [ ] Scenario 3: Skip a stop → Undo restores it as the next stop; Retry later from Needs a decision puts it back on the route; Undo works for each.
- [ ] Scenario 4: airplane mode → record Delivered → header shows "Offline · 1 outcome waiting to sync" → reconnect → row disappears after sync.
- [ ] Scenario 5: Optimize → preview shows changed positions → **Keep my order** → order unchanged, primary becomes **Start delivering**.
- [ ] All existing unit, UI and emulator tests pass (UI tests updated only for removed/renamed controls).

---

## 16. Decisions to confirm with the product owner

1. **Accent colour change** from blue `#1F5AE0` to indigo `#4338CA`. This affects the app icon only if the icon uses the brand blue; the icon is out of scope unless approved.
2. **Start delivering without optimizing** is in the route menu and becomes primary after **Keep my order**. Confirm this is discoverable enough, or add a secondary "Start with my order" link under **Optimize…**.
3. **Strip window size**: 2 before / current / 2–4 after. Real routes may have 80–150 stops; the window keeps the strip short regardless.
4. **Scan tab**: stays top-level for scanning to any route. Remove it later only if usage shows drivers always scan from inside a route.

Design canvas with all explored directions (owner's account, private): https://claude.ai/artifact/4SGAS6BdHSK7AWMr2icKq2
