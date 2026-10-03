/**
 * Server-side mirror of ParcelPilotKit `DeliveryLedger` + `Eligibility`: which stops are sent to the
 * optimizer and why the rest are not. Deterministic for any arrival order of outcomes.
 */
import type { ExcludedReason, OutcomeDoc, PackageDoc, StopDoc } from "../types";

type PackageStatus = "pending" | "delivered" | "failed" | "skipped" | "excluded";

export function packageStatuses(packages: PackageDoc[], outcomes: OutcomeDoc[]): Map<string, PackageStatus> {
  const latest = new Map<string, OutcomeDoc>();
  for (const o of outcomes) {
    if (o.voidedAt) continue;
    const current = latest.get(o.packageID);
    if (!current) { latest.set(o.packageID, o); continue; }
    const a = o.recordedAt.toMillis(), b = current.recordedAt.toMillis();
    if (a > b || (a === b && o.id > current.id)) latest.set(o.packageID, o);
  }
  const result = new Map<string, PackageStatus>();
  for (const p of packages) {
    const o = latest.get(p.id);
    if (!o || o.kind === "requeued") result.set(p.id, "pending");
    else result.set(p.id, o.kind as PackageStatus);
  }
  return result;
}

export type StopState = "pending" | "partial" | "completed" | "skipped" | "empty";

export function stopState(stopId: string, packages: PackageDoc[], statuses: Map<string, PackageStatus>): StopState {
  const mine = packages.filter((p) => p.stopID === stopId);
  if (mine.length === 0) return "empty";
  const s = mine.map((p) => statuses.get(p.id) ?? "pending");
  const handled = s.filter((x) => x === "delivered" || x === "failed" || x === "excluded").length;
  if (handled === s.length) return "completed";
  const remaining = s.filter((x) => x === "pending" || x === "skipped");
  if (remaining.every((x) => x === "skipped")) return "skipped";
  return handled > 0 ? "partial" : "pending";
}

export interface EligibleStop {
  stop: StopDoc;
  location?: { latitude: number; longitude: number };
  placeId?: string;
}

export interface EligibilityResult {
  eligible: EligibleStop[];
  excluded: Array<{ stopId: string; reason: ExcludedReason }>;
  completedStopIds: string[];
}

export function evaluateEligibility(stops: StopDoc[], packages: PackageDoc[], outcomes: OutcomeDoc[], now: Date, allowSynthetic: boolean): EligibilityResult {
  const statuses = packageStatuses(packages, outcomes);
  const ordered = [...stops].sort((a, b) => a.sequence - b.sequence || a.createdAt.toMillis() - b.createdAt.toMillis() || (a.id < b.id ? -1 : 1));
  const result: EligibilityResult = { eligible: [], excluded: [], completedStopIds: [] };
  for (const stop of ordered) {
    const state = stopState(stop.id, packages, statuses);
    if (state === "completed") { result.completedStopIds.push(stop.id); result.excluded.push({ stopId: stop.id, reason: "completed" }); continue; }
    if (state === "empty") { result.excluded.push({ stopId: stop.id, reason: "noPendingPackages" }); continue; }
    if (state === "skipped") { result.excluded.push({ stopId: stop.id, reason: "onlySkippedPackages" }); continue; }
    const okStatus = stop.addressStatus === "verified" || stop.addressStatus === "driverConfirmed" || (allowSynthetic && stop.addressStatus === "demoSynthetic");
    if (!okStatus) { result.excluded.push({ stopId: stop.id, reason: "addressNotVerified" }); continue; }
    const located = stop.resolution?.located;
    const usable = located && validPoint(located.point) && (located.expiresAt ? located.expiresAt.toMillis() > now.getTime() : located.source !== "providerGeocode");
    const placeId = stop.resolution?.placeID;
    if (!usable && !placeId) { result.excluded.push({ stopId: stop.id, reason: "noUsableLocation" }); continue; }
    result.eligible.push({ stop, location: usable ? located!.point : undefined, placeId: usable ? undefined : placeId });
  }
  return result;
}

export function validPoint(p: { latitude: number; longitude: number } | undefined): boolean {
  return !!p && Math.abs(p.latitude) <= 90 && Math.abs(p.longitude) <= 180 && !(p.latitude === 0 && p.longitude === 0);
}
