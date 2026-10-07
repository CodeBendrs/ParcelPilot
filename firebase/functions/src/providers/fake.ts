/**
 * EMULATOR-ONLY test providers. They exist so the full app ↔ functions ↔ Firestore flow can be
 * exercised locally without Google credentials or billing. They are explicitly labelled
 * `emulatorFake`, produce synthetic results, and `createProviders` refuses to use them outside the
 * Firebase Emulator Suite. They are never a production fallback.
 */
import type { OptimizeToursRequest, OptimizeToursResponse, VisitApi, TransitionApi, Waypoint } from "../optimization/googleTypes";
import { duration, parseDuration, rfc3339 } from "../optimization/time";
import type { AddressSuggester, AddressSuggestionOut, GeocodeCandidateOut, GeocodeQuery, Geocoder, SuggestQuery, TourOptimizer } from "./interfaces";

/** Approximate region anchors by postal-code first letter, used only to spread synthetic points. */
const anchors: Record<string, [number, number]> = {
  A: [47.56, -52.71], B: [44.65, -63.58], C: [46.24, -63.13], E: [45.96, -66.64], G: [46.81, -71.21], H: [45.50, -73.57],
  J: [45.40, -72.73], K: [45.42, -75.69], L: [43.59, -79.64], M: [43.65, -79.38], N: [43.45, -80.49], P: [46.49, -80.99],
  R: [49.90, -97.14], S: [52.13, -106.67], T: [51.05, -114.07], V: [48.43, -123.37], X: [62.45, -114.37], Y: [60.72, -135.06],
};

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return (h >>> 0) / 4294967295;
}

export class FakeGeocoder implements Geocoder {
  readonly provider = "emulatorFake" as const;

  async geocode(q: GeocodeQuery): Promise<GeocodeCandidateOut[]> {
    const text = q.placeId ? q.placeId.replace(/^fake-/, "").replace(/_/g, " ") : q.query ?? [...(q.address?.addressLines ?? []), q.address?.locality, q.address?.province, q.address?.postalCode].filter(Boolean).join(", ");
    if (/NOTFOUND/i.test(text)) return [];
    const postal = /([A-Z]\d[A-Z])\s?(\d[A-Z]\d)/i.exec(text);
    const civic = /(?:^|,\s*|\s)(\d{1,6})\s+([A-Za-zÀ-ÿ' .-]+?(?:St|Street|Ave|Avenue|Rd|Road|Dr|Drive|Cres|Blvd|Way|rue [A-Za-zÀ-ÿ' -]+|Ouest|Est))\b/i.exec(text);
    const letter = (postal?.[1]?.[0] ?? "M").toUpperCase();
    const [lat, lng] = anchors[letter] ?? anchors.M;
    const jitter = (k: string) => (hash(text + k) - 0.5) * 0.06;
    const location = { latitude: lat + jitter("lat"), longitude: lng + jitter("lng") };
    const postalCode = postal ? `${postal[1].toUpperCase()} ${postal[2].toUpperCase()}` : undefined;
    const province = q.address?.province ?? /\b(NL|PE|NS|NB|QC|ON|MB|SK|AB|BC|YT|NT|NU)\b/.exec(text)?.[1];
    if (civic) {
      return [{
        placeID: `fake-${hash(text).toString(36).slice(2, 10)}`,
        formattedAddress: `${civic[1]} ${civic[2]} (emulator test result)`,
        location,
        granularity: "rooftop",
        types: ["street_address"],
        streetNumber: civic[1],
        route: civic[2].trim(),
        locality: q.address?.locality,
        provinceCode: province,
        postalCode,
        countryCode: "CA",
        provider: "emulatorFake",
      }];
    }
    if (postalCode) {
      return [{ placeID: `fake-pc-${postalCode.replace(" ", "")}`, formattedAddress: `${postalCode} (emulator postal area)`, location: { latitude: lat, longitude: lng }, granularity: "approximate", types: ["postal_code"], postalCode, provinceCode: province, countryCode: "CA", provider: "emulatorFake" }];
    }
    return [];
  }
}

/** Echoes the typed text as one suggestion; its place ID round-trips through `FakeGeocoder`. */
export class FakeSuggester implements AddressSuggester {
  readonly provider = "emulatorFake" as const;

  async suggest(q: SuggestQuery): Promise<AddressSuggestionOut[]> {
    const text = q.input.trim();
    if (/NOTFOUND/i.test(text)) return [];
    const placeId = `fake-${text.replace(/[^A-Za-z0-9]+/g, "_").slice(0, 250)}`;
    return [{ placeId, primaryText: text, secondaryText: "Emulator test suggestion", provider: "emulatorFake" }];
  }
}

function pointOf(w: Waypoint | undefined): { latitude: number; longitude: number } | undefined {
  if (!w) return undefined;
  if (w.location) return w.location.latLng;
  if (w.placeId) { const h = hash(w.placeId); return { latitude: 45 + h * 3, longitude: -75 - h * 3 }; }
  return undefined;
}

function meters(a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }): number {
  const r = 6371000, toRad = Math.PI / 180;
  const dLat = (b.latitude - a.latitude) * toRad, dLng = (b.longitude - a.longitude) * toRad;
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(a.latitude * toRad) * Math.cos(b.latitude * toRad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x)) * 1.35;
}

export interface FakeOptimizerHooks {
  /** Called before responding (tests use it to edit a route mid-optimization). */
  beforeRespond?: (request: OptimizeToursRequest) => Promise<void>;
  failWith?: Error;
}

/** Straight-line nearest-neighbour solver that answers in the Route Optimization response format. */
export class FakeTourOptimizer implements TourOptimizer {
  readonly provider = "emulatorFake" as const;
  readonly requests: OptimizeToursRequest[] = [];
  constructor(private readonly hooks: FakeOptimizerHooks = {}) {}

  async optimizeTours(request: OptimizeToursRequest): Promise<OptimizeToursResponse> {
    this.requests.push(request);
    if (this.hooks.failWith) throw this.hooks.failWith;
    const speed = 30_000 / 3600;
    const vehicle = request.model.vehicles[0];
    const end = pointOf(vehicle.endWaypoint);
    const latestArrival = vehicle.endTimeWindows?.[0]?.endTime ? Date.parse(vehicle.endTimeWindows[0].endTime) : undefined;
    let clock = Date.parse(vehicle.startTimeWindows?.[0]?.startTime ?? request.model.globalStartTime);
    let position = pointOf(vehicle.startWaypoint)!;
    const shipments = request.model.shipments.map((s, i) => ({ i, s, p: pointOf(s.deliveries[0].arrivalWaypoint)! }));
    const forced = request.injectedSolutionConstraint?.routes[0]?.visits.map((v) => v.shipmentIndex);
    let remaining = forced ? forced.map((i) => shipments[i]) : [...shipments];
    const visits: VisitApi[] = [];
    const transitions: TransitionApi[] = [];
    const skipped: OptimizeToursResponse["skippedShipments"] = [];
    let travelS = 0, travelM = 0;
    let breakTaken = !vehicle.breakRule;
    const breaks: Array<{ startTime: string; duration: string }> = [];
    while (remaining.length > 0) {
      const pickIndex = forced ? 0 : remaining.reduce((best, c, idx) => (meters(position, c.p) < meters(position, remaining[best].p) ? idx : best), 0);
      const next = remaining.splice(pickIndex, 1)[0];
      let breakDuration = 0;
      if (!breakTaken && vehicle.breakRule && clock >= Date.parse(vehicle.breakRule.breakRequests[0].earliestStartTime)) {
        breakDuration = parseDuration(vehicle.breakRule.breakRequests[0].minDuration);
        breaks.push({ startTime: rfc3339(new Date(clock)), duration: duration(breakDuration) });
        clock += breakDuration * 1000;
        breakTaken = true;
      }
      const d = meters(position, next.p), t = d / speed;
      const arrival = clock + t * 1000;
      const w = next.s.deliveries[0].timeWindows?.[0];
      const startOk = w?.startTime ? Math.max(arrival, Date.parse(w.startTime)) : arrival;
      let estimatedFinish = startOk + parseDuration(next.s.deliveries[0].duration) * 1000 + (end ? meters(next.p, end) / speed * 1000 : 0);
      if (!breakTaken && vehicle.breakRule) {
        const b = vehicle.breakRule.breakRequests[0];
        estimatedFinish = Math.max(estimatedFinish, Date.parse(b.earliestStartTime)) + parseDuration(b.minDuration) * 1000;
      }
      if ((w?.endTime && startOk > Date.parse(w.endTime)) || (latestArrival !== undefined && estimatedFinish > latestArrival)) {
        skipped.push({ index: next.i, label: next.s.label, reasons: [{ code: "CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TIME_WINDOWS" }] });
        continue;
      }
      transitions.push({ travelDuration: duration(t), travelDistanceMeters: Math.round(d), waitDuration: duration((startOk - arrival) / 1000), ...(breakDuration ? { breakDuration: duration(breakDuration) } : {}), startTime: rfc3339(new Date(clock)) });
      visits.push({ ...(next.i ? { shipmentIndex: next.i } : {}), startTime: rfc3339(new Date(startOk)), shipmentLabel: next.s.label });
      travelS += t; travelM += d;
      clock = startOk + parseDuration(next.s.deliveries[0].duration) * 1000;
      position = next.p;
    }
    if (end) {
      const d = meters(position, end), t = d / speed;
      transitions.push({ travelDuration: duration(t), travelDistanceMeters: Math.round(d), startTime: rfc3339(new Date(clock)) });
      clock += t * 1000; travelS += t; travelM += d;
    }
    if (!breakTaken && vehicle.breakRule) {
      const b = vehicle.breakRule.breakRequests[0];
      const start = Math.max(clock, Date.parse(b.earliestStartTime));
      breaks.push({ startTime: rfc3339(new Date(start)), duration: b.minDuration });
      clock = start + parseDuration(b.minDuration) * 1000;
    }
    if (this.hooks.beforeRespond) await this.hooks.beforeRespond(request);
    return {
      routes: [{
        vehicleStartTime: vehicle.startTimeWindows?.[0]?.startTime ?? request.model.globalStartTime,
        vehicleEndTime: rfc3339(new Date(clock)),
        visits,
        transitions,
        breaks,
        metrics: { performedShipmentCount: visits.length, travelDuration: duration(travelS), travelDistanceMeters: Math.round(travelM) },
      }],
      ...(skipped.length ? { skippedShipments: skipped } : {}),
    };
  }
}
