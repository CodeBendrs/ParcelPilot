/**
 * Turns an OptimizeToursResponse into visits/unassigned stops and verifies it independently:
 * every shipment sent must come back exactly once — visited or skipped with a reason. Anything else
 * is treated as a provider inconsistency and the result is rejected (the driver's plan is untouched).
 */
import type { OptimizeToursResponse } from "./googleTypes";
import { parseDuration } from "./time";

export interface SegmentVisit { stopId: string; arrival: Date; start: Date; departure: Date; lateBySeconds?: number }
export interface SegmentResult {
  visits: SegmentVisit[];
  unassigned: Array<{ stopId: string; code: string; message: string; suggestions: string[] }>;
  breaks: Array<{ start: Date; durationSeconds: number }>;
  start: Date;
  end: Date;
  travelSeconds: number;
  travelMeters: number;
  serviceSeconds: number;
  waitSeconds: number;
  breakSeconds: number;
  polyline?: string;
}

export class ProviderInconsistencyError extends Error {}

const reasonText: Record<string, { message: string; suggestions: string[] }> = {
  CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TIME_WINDOWS: {
    message: "Can't be reached within its delivery window given the route's start time, other stops and break.",
    suggestions: ["Widen this stop's time window.", "Change it to “Prefer to arrive by”.", "Leave earlier or pin this stop first.", "Move a conflicting stop to another route."],
  },
  CANNOT_BE_PERFORMED_WITHIN_VEHICLE_DURATION_LIMIT: {
    message: "Doesn't fit within the route's working time.",
    suggestions: ["Remove some stops or split the route.", "Leave earlier."],
  },
  CANNOT_BE_PERFORMED_WITHIN_VEHICLE_DISTANCE_LIMIT: {
    message: "Is too far away to fit in this route.",
    suggestions: ["Check the address.", "Move it to another route."],
  },
  CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TRAVEL_DURATION_LIMIT: {
    message: "Is too far away to fit in this route.",
    suggestions: ["Check the address.", "Move it to another route."],
  },
};

export function explainSkip(code: string | undefined): { code: string; message: string; suggestions: string[] } {
  const known = code ? reasonText[code] : undefined;
  if (known) return { code: code!, ...known };
  return {
    code: code ?? "UNSPECIFIED",
    message: "The optimizer could not schedule this stop with the current constraints.",
    suggestions: ["Check this stop's time window and address.", "Relax a time window or the break, then recalculate."],
  };
}

export function interpretSegment(
  response: OptimizeToursResponse,
  shipmentStopIds: string[],
  serviceSeconds: (stopId: string) => number,
  softDeadline: (stopId: string) => Date | undefined,
  requestedStart: Date,
): SegmentResult {
  if (response.validationErrors && response.validationErrors.length > 0) {
    throw new ProviderInconsistencyError(`validation errors: ${response.validationErrors.map((v) => v.displayName ?? v.code).join(", ")}`);
  }
  const route = response.routes?.[0];
  const seen = new Map<string, number>();
  const count = (id: string) => seen.set(id, (seen.get(id) ?? 0) + 1);

  const visits: SegmentVisit[] = [];
  const transitions = route?.transitions ?? [];
  let travelSeconds = 0, travelMeters = 0, waitSeconds = 0, breakSeconds = 0, service = 0;
  (route?.visits ?? []).forEach((v, i) => {
    const index = v.shipmentIndex ?? 0;
    const stopId = v.shipmentLabel ?? shipmentStopIds[index];
    if (!stopId || !shipmentStopIds.includes(stopId) || (v.shipmentLabel && shipmentStopIds[index] !== v.shipmentLabel)) {
      throw new ProviderInconsistencyError("visit for an unknown shipment");
    }
    if (v.isPickup) throw new ProviderInconsistencyError("unexpected pickup visit");
    count(stopId);
    const start = new Date(v.startTime ?? requestedStart.toISOString());
    const wait = parseDuration(transitions[i]?.waitDuration);
    const svc = serviceSeconds(stopId);
    const deadline = softDeadline(stopId);
    const late = deadline && start.getTime() > deadline.getTime() ? Math.round((start.getTime() - deadline.getTime()) / 1000) : undefined;
    visits.push({ stopId, arrival: new Date(start.getTime() - wait * 1000), start, departure: new Date(start.getTime() + svc * 1000), ...(late ? { lateBySeconds: late } : {}) });
    service += svc;
  });
  for (const t of transitions) {
    travelSeconds += parseDuration(t.travelDuration);
    travelMeters += t.travelDistanceMeters ?? 0;
    waitSeconds += parseDuration(t.waitDuration);
    breakSeconds += parseDuration(t.breakDuration);
  }

  const unassigned: SegmentResult["unassigned"] = [];
  for (const s of response.skippedShipments ?? []) {
    const stopId = s.label ?? shipmentStopIds[s.index ?? 0];
    if (!stopId || !shipmentStopIds.includes(stopId)) throw new ProviderInconsistencyError("skipped shipment unknown");
    count(stopId);
    unassigned.push({ stopId, ...explainSkip(s.reasons?.[0]?.code) });
  }

  for (const id of shipmentStopIds) {
    const n = seen.get(id) ?? 0;
    if (n !== 1) throw new ProviderInconsistencyError(n === 0 ? "a stop is missing from the result" : "a stop appears more than once");
  }

  // Visit times must be ordered.
  for (let i = 1; i < visits.length; i++) {
    if (visits[i].start.getTime() < visits[i - 1].departure.getTime() - 1000) throw new ProviderInconsistencyError("overlapping visits");
  }

  const start = route?.vehicleStartTime ? new Date(route.vehicleStartTime) : requestedStart;
  const end = route?.vehicleEndTime ? new Date(route.vehicleEndTime) : visits.length ? visits[visits.length - 1].departure : requestedStart;
  return {
    visits,
    unassigned,
    breaks: (route?.breaks ?? []).filter((b) => b.startTime).map((b) => ({ start: new Date(b.startTime!), durationSeconds: parseDuration(b.duration) })),
    start,
    end,
    travelSeconds,
    travelMeters,
    serviceSeconds: service,
    waitSeconds,
    breakSeconds,
    polyline: route?.routePolyline?.points,
  };
}
