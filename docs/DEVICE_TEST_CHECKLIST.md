# Physical iPhone verification checklist

The Simulator has no camera, cannot run VisionKit live scanning, and does not run Vision barcode
detection. Everything below must be checked on a real iPhone (iOS 17+, ideally one older device such as
an iPhone XS/11 and one current device) before any release. Record results in
IMPLEMENTATION_STATUS.md (device, iOS version, date, pass/fail, notes). **None of these items has been
verified yet.**

Use printed copies of the synthetic labels in `fixtures/labels/` (print at 100 %, 4×6" label paper if
possible) plus a few real labels from your own deliveries (never commit images of real labels).

## Camera and permissions
- [ ] First open of Scan shows the explanation and **Allow camera**; the system prompt appears only after tapping it.
- [ ] Deny → Scan explains, offers **Open Settings**, **Import** and **Type**; manual entry works fully.
- [ ] Re-enable in Settings → return to the app → live scanner starts without relaunch.
- [ ] Screen Time camera restriction → "Camera is restricted" with import/type alternatives.
- [ ] Leaving the Scan tab and backgrounding the app turns the camera indicator (green dot) off within ~1 s; returning restarts it.
- [ ] Torch toggles on/off and turns off when leaving Scan.
- [ ] Pinch-to-zoom works; highlighting draws over recognised text and barcodes.

## Live scanning (VisionKit)
- [ ] E1 label: SHIP TO block selected, **Unit 204** preserved separately from civic 123, tracking 1Z… read from the barcode.
- [ ] E1 with unlabelled return address: return address not chosen.
- [ ] E2 French label: "DESTINATAIRE", "APP. 12", "rue Sainte-Catherine Ouest", "Montréal (Québec)", accents intact.
- [ ] Columns label (FROM | SHIP TO side by side): TO column chosen.
- [ ] Two unlabelled addresses: choice screen, no automatic selection.
- [ ] Rotated label (phone sideways / label 90°): address read.
- [ ] Glare (glossy pouch under a lamp): "Glare detected" hint appears; uncertain readings go to review.
- [ ] Blur (move while capturing): "blurry" hint; nothing auto-added.
- [ ] Partially covered label (cover the city line): incomplete card lists missing fields; nothing invented.
- [ ] Tracking-only barcode: "no delivery address" message; nothing added.
- [ ] QR vCard label: explicit address used.
- [ ] Low light: torch hint usable; recognition levels drop and are reported honestly.

## Batch mode
- [ ] Enable batch: 10 clear labels in a row → 10 adds with success haptic and Undo toast each; holding a label in view does **not** add it twice.
- [ ] Same tracking number presented again later → warning haptic + "Already scanned"; no new package.
- [ ] Second package for the same destination → "existing stop", package count 2.
- [ ] Different unit, same building → new stop.
- [ ] Ambiguous / glare / partial labels → "Sent to review" without stopping the camera; review queue count increases.
- [ ] Undo after an auto-add removes the package (and the stop when it was new).

## Offline
- [ ] Airplane mode: scans save as "Needs address verification"; app relaunch keeps the review queue.
- [ ] Record Delivered offline → force-quit → relaunch → still delivered → reconnect → appears once in Firestore console; the sync indicator goes from Offline → Syncing → Synced.
- [ ] Optimize while offline shows the offline message; stops unchanged.

## Navigation hand-off (E9)
- [ ] Apple Maps opens with the building address (no unit); the unit badge stays on the stop card.
- [ ] Google Maps app opens when installed; the web fallback opens in Safari when it is not.
- [ ] Returning to ParcelPilot shows the same stop with "Back from navigation"; nothing is marked delivered.

## Proof of delivery
- [ ] Take a photo after Delivered → saved immediately; uploads when online; visible in stop details; delete removes it from Storage.
- [ ] Take a photo offline → force-quit → relaunch online → upload resumes once (no duplicate object).
- [ ] Photo EXIF has no GPS (check the downloaded file).

## Accounts (production project)
- [ ] Continue with Google (new account and returning account); cancelling the Google sheet returns to the sign-in screen without an error.
- [ ] Create an email account → verification email arrives → "Confirm your email" banner → open the link → "I've opened the link" clears it; address checks and Optimize work only after that.
- [ ] Forgot password → reset email arrives → new password works; a wrong password shows "Email or password is incorrect."
- [ ] With `PP_APPLE_DEVELOPER_PROGRAM = YES` (paid membership): Sign in with Apple (new and returning account).
- [ ] Sign out with unsynced changes shows the warning; data removed from the device.
- [ ] Delete account: confirm with your password (email) or Google → data gone from Firestore/Storage/Auth. Apple accounts: Apple confirmation sheet, and Apple ID → Sign in with Apple no longer lists ParcelPilot.
- [ ] Disable the account in the Firebase console (or delete it from a second device) while the app has unsynced changes → within an hour (or on next launch/foreground) the app either shows the "Sign in again" banner or returns to the sign-in screen with an explanation — never a session that looks fine while nothing syncs. Signing in again with the same account (for a disabled-then-re-enabled account) syncs the queued changes; a different account is refused from the banner with an explanation.

## Map and routing (production)
- [ ] Google map renders with markers and route polylines; Google logo visible above the panel at all panel heights.
- [ ] Optimize 10 / 50 / 200 stops; record the times in IMPLEMENTATION_STATUS.md (live measurements).
- [ ] Incompatible hard windows → unassigned stops with suggestions; all packages remain.
- [ ] Edit a stop while optimizing → "The route changed" (stale); edit kept.
- [ ] Pins: first/last honoured; fixed next stop honoured when re-planning from current location.

## Accessibility and layout
- [ ] VoiceOver: next-stop card reads stop number, address, unit, packages; actions reachable; panel expand/collapse actions available.
- [ ] Largest accessibility text size: Delivered/Failed/Skip remain visible; unit numbers not clipped.
- [ ] Dark mode, Reduce Motion, Increase Contrast.
- [ ] iPhone SE-size device and Pro Max.
