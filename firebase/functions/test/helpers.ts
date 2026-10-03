import { Timestamp } from "firebase-admin/firestore";
import type { OutcomeDoc, PackageDoc, RouteDoc, StopDoc } from "../src/types";

export const T0 = new Date("2026-10-05T15:00:00Z");

export function routeDoc(extra: Partial<RouteDoc> = {}): RouteDoc {
  return {
    id: "r1", schemaVersion: 1, name: "Test", status: "planning", serviceDate: "2026-10-05", timeZoneID: "America/Vancouver",
    departureMinute: 480,
    start: { label: "Depot", located: { point: { latitude: 48.4284, longitude: -123.3656 }, source: "driverPin" } },
    returnToStart: true, defaultServiceSeconds: 120, objective: "balanced", considerTraffic: true, inputRevision: 1,
    ...extra,
  };
}

export function stopDoc(n: number, extra: Partial<StopDoc> = {}): StopDoc {
  return {
    id: `s${n}`,
    address: { civicNumber: `${100 + n}`, streetName: "EXAMPLE ST", municipality: "VICTORIA", province: "BC", postalCode: "V8W 1A1" },
    destinationKey: `C|${100 + n}|EXAMPLE ST||V8W1A1`,
    addressStatus: "verified",
    resolution: {
      provider: "google", placeID: `place-${n}`, match: "building", resolvedAt: Timestamp.fromDate(T0),
      located: { point: { latitude: 48.40 + (n % 10) * 0.007, longitude: -123.40 + Math.floor(n / 10) * 0.009 }, source: "providerGeocode", expiresAt: Timestamp.fromMillis(T0.getTime() + 20 * 86_400_000) },
    },
    sequence: n,
    pin: "none",
    createdAt: Timestamp.fromDate(T0),
    ...extra,
  };
}

export function packageDoc(n: number, stopId = `s${n}`): PackageDoc {
  return { id: `p${n}`, stopID: stopId, createdAt: Timestamp.fromDate(T0) };
}

export function outcomeDoc(id: string, packageId: string, stopId: string, kind: OutcomeDoc["kind"], atMs: number, voided = false): OutcomeDoc {
  return { id, packageID: packageId, stopID: stopId, kind, recordedAt: Timestamp.fromMillis(atMs), ...(voided ? { voidedAt: Timestamp.fromMillis(atMs + 1000) } : {}) };
}
