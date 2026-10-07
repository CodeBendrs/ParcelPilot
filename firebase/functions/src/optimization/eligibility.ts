/**
 * Server-side mirror of ParcelPilotKit `WorkLedger` + `Eligibility`: which stops are sent to the
 * optimizer and why the rest are not. Deterministic for any arrival order of outcomes.
 */
import type { ExcludedReason, LocationTaskDoc, OutcomeDoc, PackageDoc, StopDoc } from "../types";

type PackageStatus = "pending" | "delivered" | "failed" | "skipped" | "excluded";
export type WorkStatus = "pending" | "completed" | "failed" | "deferred" | "excluded" | "unsupported";

export function deliveryTaskId(packageId: string): string { return `delivery_${packageId}`; }

interface WorkItem { id: string; stopID: string; required: boolean; kind: string }

function workItems(packages: PackageDoc[], tasks: LocationTaskDoc[]): WorkItem[] {
  return [
    ...packages.map((p) => ({ id: deliveryTaskId(p.id), stopID: p.stopID, required: true, kind: "delivery" })),
    ...tasks.map((task) => task.schemaVersion !== 1 || task.kind === "delivery" || task.id.startsWith("delivery_")
      ? { ...task, kind: "unsupported" } : task),
  ];
}

/** One outcome reducer for both legacy package deliveries and generalized location work. */
export function workStatuses(packages: PackageDoc[], tasks: LocationTaskDoc[], outcomes: OutcomeDoc[]): Map<string, WorkStatus> {
  const items = workItems(packages, tasks);
  const byId = new Map(items.map((item) => [item.id, item]));
  const latest = new Map<string, OutcomeDoc>();
  const blocked = new Set<string>();
  const unique = new Map<string, OutcomeDoc>();
  // A definition must not shadow another task or a package projection. Firestore normally gives
  // each definition a unique document ID; imported/corrupt data still fails closed.
  for (const item of items) {
    const sameId = items.filter((other) => other.id === item.id);
    if (sameId.some((other) => other.stopID !== item.stopID || other.kind !== item.kind || other.required !== item.required)) blocked.add(item.id);
  }
  const targets = (outcome: OutcomeDoc) => [outcome.taskID, outcome.packageID ? deliveryTaskId(outcome.packageID) : undefined]
    .filter((id): id is string => !!id && byId.has(id));
  for (const outcome of outcomes) {
    const duplicate = unique.get(outcome.id);
    if (!duplicate) { unique.set(outcome.id, outcome); continue; }
    if (outcomePayload(duplicate) !== outcomePayload(outcome)) {
      for (const id of [...targets(duplicate), ...targets(outcome)]) blocked.add(id);
    } else if (outcome.voidedAt && !duplicate.voidedAt) {
      // A repeated active copy cannot resurrect an event that another copy voided.
      unique.set(outcome.id, outcome);
    }
  }
  for (const outcome of unique.values()) {
    const id = outcome.taskID ?? (outcome.packageID ? deliveryTaskId(outcome.packageID) : undefined);
    const item = id ? byId.get(id) : undefined;
    if (!id || !item) {
      // Genuine removed-work history is inert. A schema 2 event that falsely names an unknown
      // task while still claiming an existing package must not bypass identity validation.
      if (outcome.schemaVersion === 2 && outcome.packageID && byId.has(deliveryTaskId(outcome.packageID))) blocked.add(deliveryTaskId(outcome.packageID));
      continue;
    }
    const schema = outcome.schemaVersion ?? 1;
    const validKind = ["delivered", "completed", "failed", "skipped", "excluded", "requeued"].includes(outcome.kind)
      && (item?.kind === "delivery" ? outcome.kind !== "completed" : outcome.kind !== "delivered");
    const validIdentity = schema === 1 ? !!outcome.packageID && !outcome.taskID && item?.kind === "delivery"
      : schema === 2 && !!outcome.taskID && (item?.kind === "delivery"
        ? !!outcome.packageID && id === deliveryTaskId(outcome.packageID)
        : !outcome.packageID);
    if (item.stopID !== outcome.stopID || !validIdentity || !validKind) {
      for (const target of targets(outcome)) blocked.add(target);
      continue;
    }
    if (outcome.voidedAt) continue;
    const current = latest.get(id);
    if (!current || outcome.recordedAt.toMillis() > current.recordedAt.toMillis()
      || (outcome.recordedAt.toMillis() === current.recordedAt.toMillis() && outcome.id > current.id)) latest.set(id, outcome);
  }
  const result = new Map<string, WorkStatus>();
  for (const item of items) {
    if (blocked.has(item.id) || !["delivery", "pickup", "checklist"].includes(item.kind)) { result.set(item.id, "unsupported"); continue; }
    const outcome = latest.get(item.id);
    if (!outcome || outcome.kind === "requeued") { result.set(item.id, "pending"); continue; }
    switch (outcome.kind) {
      case "delivered": result.set(item.id, item.kind === "delivery" ? "completed" : "unsupported"); break;
      case "completed": result.set(item.id, item.kind !== "delivery" ? "completed" : "unsupported"); break;
      case "failed": result.set(item.id, "failed"); break;
      case "skipped": result.set(item.id, "deferred"); break;
      case "excluded": result.set(item.id, "excluded"); break;
      default: result.set(item.id, "unsupported");
    }
  }
  return result;
}

function outcomePayload(outcome: OutcomeDoc): string {
  return JSON.stringify([
    outcome.schemaVersion ?? 1, outcome.packageID ?? null, outcome.taskID ?? null,
    outcome.stopID, outcome.kind, outcome.recordedAt.toMillis(), outcome.reason ?? null,
    outcome.note ?? null, outcome.photoIDs ?? [],
  ]);
}

export function packageStatuses(packages: PackageDoc[], outcomes: OutcomeDoc[]): Map<string, PackageStatus> {
  const statuses = workStatuses(packages, [], outcomes);
  const result = new Map<string, PackageStatus>();
  for (const p of packages) {
    const state = statuses.get(deliveryTaskId(p.id)) ?? "pending";
    result.set(p.id, state === "completed" ? "delivered" : state === "deferred" ? "skipped" : state === "unsupported" ? "pending" : state);
  }
  return result;
}

export type StopState = "pending" | "partial" | "completed" | "skipped" | "empty";

export function stopState(stopId: string, packages: PackageDoc[], statuses: Map<string, PackageStatus>): StopState {
  const mine = packages.filter((p) => p.stopID === stopId);
  const states = mine.map((p): WorkStatus => {
    const state = statuses.get(p.id) ?? "pending";
    return state === "delivered" ? "completed" : state === "skipped" ? "deferred" : state;
  });
  // PackageStatus cannot produce unsupported work.
  return classifyRequiredStates(states) as StopState;
}

function workStopState(stopId: string, items: WorkItem[], statuses: Map<string, WorkStatus>): StopState | "unsupported" {
  const required = items.filter((item) => item.stopID === stopId && item.required);
  const states = required.map((item) => statuses.get(item.id) ?? "pending");
  return classifyRequiredStates(states);
}

function classifyRequiredStates(states: WorkStatus[]): StopState | "unsupported" {
  if (states.length === 0) return "empty";
  if (states.includes("unsupported")) return "unsupported";
  const handled = states.filter((state) => ["completed", "failed", "excluded"].includes(state)).length;
  if (handled === states.length) return "completed";
  const remaining = states.filter((state) => state === "pending" || state === "deferred");
  if (remaining.every((state) => state === "deferred")) return "skipped";
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

export function evaluateEligibility(stops: StopDoc[], packages: PackageDoc[], outcomes: OutcomeDoc[], now: Date, allowSynthetic: boolean, tasks: LocationTaskDoc[] = []): EligibilityResult {
  const items = workItems(packages, tasks);
  const statuses = workStatuses(packages, tasks, outcomes);
  const ordered = [...stops].sort((a, b) => a.sequence - b.sequence || a.createdAt.toMillis() - b.createdAt.toMillis() || (a.id < b.id ? -1 : 1));
  const result: EligibilityResult = { eligible: [], excluded: [], completedStopIds: [] };
  for (const stop of ordered) {
    const state = workStopState(stop.id, items, statuses);
    if (state === "unsupported") { result.excluded.push({ stopId: stop.id, reason: "unsupportedTasks" }); continue; }
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
