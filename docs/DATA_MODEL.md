# ParcelPilot data model

All user data lives under `users/{uid}` in Cloud Firestore (region `northamerica-northeast1`).
Field names are the Swift property names (the iOS app writes documents with the Firestore Codable
encoder); optional fields are absent when unset. Every record has a stable, client-generated ID so
offline writes and retries are idempotent.

**Ownership legend** — *Driver*: data the driver entered or confirmed (kept until they delete it or their
account). *Provider*: Google Maps Platform content (expires; see retention). *Server*: written only by
Cloud Functions; clients can at most read it.

## Collections

```
users/{uid}                                   User (settings)                 Driver
users/{uid}/routes/{routeId}                  Route                           Driver (+ provider fields)
users/{uid}/routes/{routeId}/stops/{stopId}   Stop (a delivery destination)   Driver (+ provider fields)
users/{uid}/routes/{routeId}/packages/{id}    Package                         Driver
users/{uid}/routes/{routeId}/outcomes/{id}    DeliveryOutcome (append-only)   Driver
users/{uid}/routes/{routeId}/photos/{id}      DeliveryPhoto metadata          Driver
users/{uid}/optimizationRequests/{requestId}  OptimizationRequest / job       Server (owner may read)
users/{uid}/optimizationLocks/{routeId}       one-active-job lock             Server (no client access)
users/{uid}/usage/{YYYY-MM-DD}                daily usage counters            Server (no client access)
system/usage/months/{YYYY-MM}                 project-wide monthly counters   Server (no client access)
Cloud Storage users/{uid}/routes/{routeId}/pod/{photoId}.jpg   proof-of-delivery JPEG   Driver
```

## User — `users/{uid}`
| Field | Type | Notes |
|---|---|---|
| schemaVersion | int | 1 |
| settings.navigationApp | `appleMaps` \| `googleMaps` \| `ask` | |
| settings.distanceUnit | `kilometres` \| `miles` | |
| settings.defaultServiceSeconds | int 0–3600 | default time at stop for new routes |
| settings.batchScanDefault | bool | |
| createdAt, updatedAt | timestamp | |

## Route — `routes/{routeId}`
| Field | Type | Persistence |
|---|---|---|
| id, schemaVersion, name, status (`planning`/`active`/`completed`/`archived`) | | Driver |
| createdAt, updatedAt, startedAt?, completedAt?, archivedAt? | timestamp | Driver |
| serviceDate | `YYYY-MM-DD` | Driver |
| timeZoneID | IANA `America/*` | Driver — every wall-clock time on the route uses it |
| departureMinute | int, wall-clock minutes after local midnight (≥1440 = next day) | Driver |
| latestArrivalMinute? | int > departureMinute and < 2880; hard latest arrival at Start when returning, otherwise End; includes return travel, service, waiting and required break | Driver; omitted when disabled, older routes have no limit |
| start?, end? | RoutePlace `{label, address?, located?, placeID?}` | label/address: Driver; `located` from Google: Provider (≤30 days); device location / pins: Driver |
| returnToStart | bool | Driver |
| defaultServiceSeconds | int | Driver |
| breakRule? | `{earliestStartMinute, latestStartMinute, durationSeconds}` | Driver |
| objective | `balanced` \| `fastest` | Driver |
| considerTraffic | bool | Driver |
| inputRevision | int ≥ 1, never decreases | Driver; incremented atomically on every optimization-input change |
| appliedRequestID?, appliedRevision? | | which optimization's order is applied |
| nextStopOverrideID? | | driver's chosen next stop |
| summary? | counts + first/last outcome time | Driver (derived when finishing/archiving) |
| plannedDistance? | `{meters, provider, calculatedAt, expiresAt}` | Provider content, expiry ≤ 24 h (rules allow ≤ 2 days) |

## Stop — `stops/{stopId}` (a delivery destination)
| Field | Type | Persistence |
|---|---|---|
| address | PostalAddress `{recipientName?, unit?, unitDesignator?, civicNumber?, streetName?, deliveryInstallation?, municipality?, province?, postalCode?, country?, additionalLines}` | Driver-confirmed text (accents preserved) |
| destinationKey | `C|civic|street|unit|postal` normalized | Driver (derived). Same key ⇒ same stop. Coordinates never merge stops. |
| addressStatus | `verified` (Google building match only — enforced by rules), `driverConfirmed`, `pendingVerification`, `needsReview`, `unresolvable`, `demoSynthetic` | Driver |
| resolution? | `{provider?, placeID?, located?, match, resolvedAt}` | placeID: kept indefinitely (exempt from caching limits); `located` from Google: Provider, expiresAt ≤ 30 days (rules enforce ≤ 31); driver pin: Driver |
| reviewReasons | [ReviewReason] | Driver |
| sequence | number | Driver (manual or applied order) |
| pin | `none` \| `first` \| `last` | Driver |
| timeWindow? | `{kind: hard \| softDeadline, startMinute?, endMinute}` | Driver. `hard` = must arrive within; `softDeadline` = prefer to arrive by |
| serviceSeconds? | int | Driver (overrides route default) |
| notes | string ≤ 2000 | Driver (may contain access codes — never logged) |

## Package — `packages/{packageId}`
| Field | Notes |
|---|---|
| stopID | the destination it belongs to |
| trackingID?, trackingKey? | as printed / normalized for lookup and duplicate detection |
| recipientName?, size?, storageLocation?, notes, source (`scan`/`manual`/`paste`/`csv`/`duplicate`) | Driver |

## DeliveryOutcome — `outcomes/{outcomeId}` (append-only)
| Field | Notes |
|---|---|
| packageID, stopID, kind (`delivered`/`failed`/`skipped`/`requeued`/`excluded`), reason?, note?, photoIDs | |
| recordedAt | device time when the driver recorded it (actual, not planned) |
| voidedAt? | set once by Undo |

Rules: create-only; the only permitted update adds `voidedAt` once (or an identical replay); delete
is never allowed. Package status = latest non-voided outcome by (`recordedAt`, `id`). `requeued`
returns a package to remaining work; `excluded` counts as handled. A stop is complete only when all
its packages are delivered, failed or excluded.

## DeliveryPhoto — `photos/{photoId}`
`{stopID, packageIDs, storagePath = users/{uid}/routes/{routeId}/pod/{photoId}.jpg, contentType = image/jpeg, byteSize ≤ 5 MB, capturedAt}` — Driver.
JPEGs are re-encoded on device (no EXIF/GPS). Pending uploads live in `Application Support/PendingUploads/{uid}` until uploaded.

## OptimizationRequest — `optimizationRequests/{requestId}` (server-written)
| Field | Notes |
|---|---|
| id, routeId, inputRevision, status (`queued`/`running`/`succeeded`/`infeasible`/`failed`/`stale`/`cancelled`) | |
| provider | `google` or `emulatorFake` (emulator only) |
| options | origin kind, fixed next stop, baseline, traffic, departNow |
| proposal? | `{requestId, routeId, inputRevision, provider, status, calculatedAt, expiresAt, trafficConsidered, origin, fixedNextStopId, visits[{stopId, arrival, start, departure, lateBySeconds?}], unassigned[{stopId, code, message, suggestions}], excluded[{stopId, reason}], breaks[], metrics, baseline, baselineNote, polylines[], completedStopIdsAtRequest[], warnings[]}` — **Provider content** |
| error? | `{reason, message, suggestions}` |
| billing | `{requests, shipmentsSubmitted, providerMillis}` |
| createdAt, updatedAt, expiresAt | `expiresAt` = +24 h; Firestore TTL policy + scheduled purge delete the document |

## Retention summary

| Content | Kept | Mechanism |
|---|---|---|
| Driver data (routes, stops, packages, outcomes, notes, photos, driver pins) | Until the driver deletes it or the account | `deleteAccount` removes everything |
| Google place IDs | Indefinitely | Exempt from caching restrictions |
| Google geocode coordinates (stops, start/end) | ≤ 30 days | `expiresAt` checked by app and rules; `purgeExpiredProviderContent` strips them daily; refreshed by place ID |
| Optimization proposals (ETAs, distances, polylines) | 24 hours | Job `expiresAt` + Firestore TTL + daily purge; app hides expired plans |
| Planned distance on a route | 24 hours | `plannedDistance.expiresAt`, purged daily |
| Label images and full OCR text | Never stored | In memory during processing only |
| Scan drafts (review queue) | Until confirmed/discarded | On-device JSON (`completeUntilFirstUserAuthentication`); only the recipient block lines and chosen fields |
| Device location | Not stored (only the start you choose or a one-off origin in a job that expires in 24 h) | |
| Usage counters | Indefinitely (no personal content) | server-only |

## Indexes
`firestore.indexes.json`: `routes(status ASC, updatedAt DESC)`; collection-group single-field
indexes for the retention queries; TTL on `optimizationRequests.expiresAt`.
