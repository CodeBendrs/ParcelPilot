# WP1 — Unified location work model

Implemented scope: additive work definitions, one outcome reducer, compatible persistence, task-aware route progress/optimization eligibility, and proposal revision coverage for work mutations. This does not implement WP2's local durability contract.

## Source of truth

- Packages remain the delivery definitions. `LocationTask.projection(for:)` supplies the stable work identity `delivery_<packageID>`; no delivery task documents or copied package fields are created.
- Independent pickup/checklist definitions live in `routes/{routeID}/tasks/{taskID}`. An optional package association is descriptive; the task has its own outcome and no cross-stop dependency.
- The existing `outcomes` collection remains the only completion/disposition history. `TaskOutcome` is the generalized type; `DeliveryOutcome` is a source compatibility alias.
- `WorkLedger` reduces definitions and non-voided events. `DeliveryLedger` is a package-status compatibility facade over that reducer, not a second reducer. Summaries, next-stop selection and eligibility consume the derived state.
- The backend's eligibility reducer mirrors these semantics before creating Google optimizer input. No solver or routing-provider change was made.

## State semantics

| Work state | Handled | Successful | Creates remaining-route eligibility | Retry |
| --- | --- | --- | --- | --- |
| Pending | No | No | Yes, if required and address usable | No-op |
| Completed | Yes | Yes | No | No-op |
| Failed | Yes | No | No | Appends `requeued` → pending |
| Deferred | No | No | No until Retry | Appends `requeued` → pending |
| Excluded | Yes | No | No | No-op |
| Unsupported | No | No | Blocks plan generation/acceptance if required | Requires compatible data/app |

Legacy `skipped` events map to deferred work. Failed work remains an explicit unsuccessful disposition. Optional work appears in the work catalog and presentation queries but never creates a visit or blocks required-work completion. At a required visit it can still be completed explicitly.

A stop is handled when every required item is completed, failed or excluded. Some handled plus some pending produces partial progress. If all remaining required work is deferred, the existing skipped-stop status is preserved. Optional-only stops are empty for route-progress/optimization purposes.

Undo voids an active outcome, revealing the previous non-voided outcome or pending state. Undo of Retry restores its prior failed/deferred disposition. Store-level repeated completion, invalid Retry and repeated Undo are no-ops. Toast Undo uses current route data even when its closure captured the pre-outcome view snapshot.

Event reduction retains legacy `(recordedAt, eventID)` ordering. Identical duplicate events reduce once; a voided copy wins over an active copy. Conflicting payloads sharing an event ID and incorrect targeting make known affected work unsupported. Removed work can retain orphan historical outcomes without recreating obligations. Unknown task kinds remain decodable and visible; required unknown work cannot silently disappear.

## Additive wire contract

| Record | Version | Compatibility |
| --- | --- | --- |
| Route / Stop / Package | Existing version 1 | No destructive changes |
| Delivery outcome | Existing version 1 | Required packageID, no taskID; existing writes preserve this shape |
| Generalized outcome | Version 2 | Required taskID; standalone outcomes omit packageID and use `completed` for success |
| Location task definition | Version 1 | Stable id/stopID/kind; required flag, title, instructions, orderRank, optional packageID, timestamps |
| Route summary | Existing route version | Local optional `work` counters; Firestore writes omit this redundant cache to fit rules evaluation limits |

Generalized delivery events, if supplied, must target `delivery_<packageID>` and include the matching packageID. They cannot use the standalone `completed` disposition. Standalone task outcomes cannot use `delivered` or target a package. Persisted task definitions cannot use delivery kind or the reserved delivery identity prefix.

Work summary disposition counters count required work only: completed, failed, deferred, excluded, pending and unsupported sum to required. Optional work has a separate count. A successful task must never inflate legacy delivered-package counts.

`RouteSnapshot.workSummary` always derives from persisted definitions/outcomes. The optional `RouteSummary.work` cache is retained for local serialization and decoding compatibility, but omitted from Firestore route writes. Emulator regression showed that adding it to an otherwise valid warehouse/accepted-proposal close-out document exceeds Firestore's 1000-expression rules budget. Omitting this cache preserves all task/outcome records and keeps close-out working without a broader rules rewrite.

Existing local JSON files without a tasks field decode with an empty task collection. Frozen legacy outcome and journal wire formats remain readable. No history is rewritten. Task identity, owning stop, kind and package association are immutable once created; instruction/order/required edits invalidate proposals.

Firestore rules validate task targets, package associations and generalized outcome targets. New task mutations and schema-2 create/Undo require a same-batch route revision advance. Fresh route plus task creation is also supported atomically. Schema-1 writes stay compatible with existing clients.

Route rule updates validate every changed nested map, while avoiding repeated deep validation of unchanged warehouse/break/distance/summary maps. Root keys, scalar types, nested map types and cross-field invariants remain checked on every write; creation validates every present nested map. Emulator tests cover the real staged warehouse close-out and metadata edits attempting to smuggle changed nested data. This narrow budget fix was necessary even after omitting the work-summary cache.

## Revisions and persistence limits

Successful outcomes, failure, defer, Retry and Undo bump `inputRevision`, including pickup/checklist outcomes. Partial delivery retains the next-stop override until all required work at that stop is handled. Proposal acceptance checks current route identity/revision even when the caller retained an older snapshot.

Critical-write journal entries retain a narrow route revision bump rather than a stale serialized route. Explicit Retry of legacy journal entries adds a conservative bump if none existed. Reconciliation only acknowledges operations whose server state can be verified; an unavailable read remains pending. Task verification compares the definition payload, not just document existence.

Generalized outcome and copied-task batches contain at most six work targets plus a revision write. This conservatively fits security-rule reference-read budgets even when targets use distinct stops/packages. Each committed batch advances the revision; this is not one globally atomic command. Existing delivery-only batch sizing remains unchanged. Copying starts work with fresh task/package/stop identities and no outcomes or photos; stop-removal Undo restores definitions alongside the existing outcomes.

Firestore collection decode failures preserve the last complete collection and expose a read issue. They block work recording, optimization and close-out until the route can be read safely. Unknown required definitions also block optimization and close-out. These guards avoid presenting malformed data as an empty or completed route.

**This is not a local write-acknowledgement guarantee.** Existing JSON/journal writes still use the existing persistence mechanisms; Firestore local updates/server callbacks are not proof of WP2 durability. No protected active-route snapshot, transactional outbox, event receipts or exactly-once command protocol has been added.

## Files

Paths below are repository-relative for portability.

| Area | Files |
| --- | --- |
| Domain | `Packages/ParcelPilotKit/Sources/ParcelPilotKit/Tasks/LocationTask.swift`, `Tasks/WorkLedger.swift`, `Model/Core.swift`, `Model/RouteModels.swift`, `Delivery/DeliveryProgress.swift` |
| Routing integration | `Packages/ParcelPilotKit/Sources/ParcelPilotKit/Routing/OptimizationModels.swift`, `Routing/DemoOptimizer.swift` |
| Store/persistence | `ParcelPilot/Services/Core/Backend.swift`, `Core/RouteStore.swift`, `Demo/LocalRouteBackend.swift`, `Firebase/FirestoreRouteBackend.swift`, `Firebase/SyncJournal.swift` |
| Minimal existing-UI compatibility | `ParcelPilot/DesignSystem/FocusComponents.swift`, `Features/Deliver/DeliveryPanel.swift`, `Features/Optimize/OptimizeSheet.swift`, `Features/Stops/StopDetailView.swift`, `Features/Workspace/RouteWorkspaceView.swift` |
| Backend/rules | `firebase/firestore.rules`, `firebase/functions/src/types.ts`, `optimization/eligibility.ts`, `optimization/run.ts` |
| Tests | `Packages/ParcelPilotKit/Tests/ParcelPilotKitTests/WorkLedgerTests.swift`, `ParcelPilotTests/WorkStoreTests.swift`, `ParcelPilotTests/FirestoreBackendEmulatorTests.swift`, `firebase/functions/test/unit.test.ts`, `test/integration/handlers.test.ts`, `firebase/tests/firestore.rules.test.ts` |

## Verification

Tests cover legacy wire decoding, package/unit identity, partial delivery, failed/deferred Retry, Undo, pickup-only and checklist-only work, mixed work, optional-only completion/eligibility, deterministic/conflicting replay, task persistence/copy/removal, current-snapshot mutation guards, every relevant outcome revision and stale proposals. SDK/emulator tests exercise actual serialization, rules, journal Retry and malformed listener reads. Handler integration verifies persisted tasks influence optimizer input before the provider is called.

Final verification on October 5, 2026:

| Check | Result |
| --- | --- |
| `swift test` in `Packages/ParcelPilotKit` | 127 passed; 30 new work-model tests |
| iOS app + real SDK tests, Auth/Firestore/Storage emulators | 52 passed: 40 app/compatibility tests and 12 SDK tests |
| Focused driver UI regressions | 3 passed: partial delivery/failure/exclusion Undo, Skip/Retry Undo, offline relaunch |
| Functions unit tests (`npm test`) | 61 passed |
| Functions emulator handler integration (`npm run test:integration`) | 38 passed, rerun after final eligibility changes |
| Firestore / Storage security rules | 34 / 3 passed |
| Functions type check (`npm run lint`) / repository whitespace check | Passed |

The SDK run excluded the unchanged `emailAccount()` callable/email test because the Functions emulator was not started. The other 12 SDK tests executed, including the staged warehouse close-out, malformed reads, journal replay, and eight-pickup batch/copy regression. SDK testing used simulator ad-hoc signing and `TEST_RUNNER_PP_EMULATOR=1`; all Firebase SDK work assertions used the demo project's emulators. Test and build output is in `/tmp/parcelpilot-wp1-*.log` and `/tmp/parcelpilot-wp1-derived/Logs/Test/` on this host.

## Deferred behavior and WP2 handoff

- Arrival sensing, voice, BC geocoding, external-navigation changes and arrival-task UI remain untouched.
- There is a domain/test task-creation API, with no production pickup/checklist entry screen. Future entry/arrival UI consumes `WorkLedger`; it must not introduce a second completion state.
- Cross-stop pickup-to-delivery dependencies and task-level time windows remain deferred. Existing stop windows are retained.
- Manual reorder and chosen-next-stop revision behavior remains the existing behavior; extend their proposal safeguards in the route-editing work package.
- Route writer promotion/single-device leases and old-client exclusion are not implemented. An older binary can still ignore task collections. Do not enable generalized-work pilot writers until the compatibility/writer gate in the later package is in place.
- Client-clock ordering remains legacy-compatible and does not establish causal order across devices or clock changes. WP2 must specify durable command order and conflict handling.
- Protected snapshot/local commit acknowledgement, storage exhaustion/corruption recovery, account-bound replay, transactional retry persistence and receipts are WP2 responsibilities. Historical legacy journal entries already automatically reconciled cannot prove revision coverage.
- Multi-batch copying and large work groups do not become all-or-nothing transactions. WP2 must make partial sync/rejection explicit while preserving all local intents.
- Creation of maximally populated route documents containing both full warehouse addresses and every optional field has a pre-existing rules-budget limit, even without generalized summary data. Normal staged edits/close-out are now covered; investigate creation of the maximal shape separately before enabling it.
- No Firebase rules/functions were deployed and no production resources were changed.
