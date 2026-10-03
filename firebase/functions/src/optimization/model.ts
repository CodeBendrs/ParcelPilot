/**
 * Builds Route Optimization requests for one vehicle.
 *
 * Pins are enforced structurally rather than with precedence rules (Google documents that precedence
 * rules over many shipments may be rejected): a pinned-first stop (or the driver's fixed next stop)
 * is solved as a one-shipment *prefix* from the origin; the *main* segment starts at that stop at the
 * prefix's finishing time and ends at the pinned-last stop's location; a one-shipment *suffix* serves
 * the last stop and drives to the route end. Each segment's start time is the previous segment's
 * actual end time, so every ETA is a real solver output — nothing is swapped after solving.
 */
import type { EligibleStop } from "./eligibility";
import type { BreakRequestApi, OptimizeToursRequest, ShipmentApi, TimeWindowApi, VehicleApi, Waypoint } from "./googleTypes";
import { duration, rfc3339 } from "./time";

export type Objective = "balanced" | "fastest";

export interface StopWindow { kind: "hard" | "softDeadline"; start?: Date; end: Date }

export interface PlanInputs {
  eligible: EligibleStop[];
  serviceSeconds: (stopId: string) => number;
  windows: Map<string, StopWindow>;
  origin: Waypoint;
  routeEnd?: Waypoint;
  departure: Date;
  breakWindow?: { earliest: Date; latest: Date; durationSeconds: number };
  firstStopId?: string;
  lastStopId?: string;
  objective: Objective;
  considerTraffic: boolean;
}

export type SegmentKind = "prefix" | "main" | "suffix";

export interface SegmentPlan {
  kind: SegmentKind;
  stopIds: string[];
  /** Waypoint the vehicle starts from (origin, the first stop, or the last stop's location). */
  start: Waypoint | "previousEnd";
  end?: Waypoint;
  carriesBreak: boolean;
}

export function costs(objective: Objective): { costPerHour: number; costPerKilometer: number } {
  // Never all-zero: the solver needs an objective. Units are relative weights, not currency.
  return objective === "fastest" ? { costPerHour: 60, costPerKilometer: 0.05 } : { costPerHour: 40, costPerKilometer: 0.6 };
}

export function waypointFor(s: EligibleStop): Waypoint {
  return s.location ? { location: { latLng: { latitude: s.location.latitude, longitude: s.location.longitude } } } : { placeId: s.placeId! };
}

/** Segments to solve, in order. */
export function planSegments(inputs: PlanInputs): SegmentPlan[] {
  const ids = inputs.eligible.map((e) => e.stop.id);
  const first = inputs.firstStopId && ids.includes(inputs.firstStopId) ? inputs.firstStopId : undefined;
  const last = inputs.lastStopId && ids.includes(inputs.lastStopId) && inputs.lastStopId !== first ? inputs.lastStopId : undefined;
  const middle = ids.filter((id) => id !== first && id !== last);
  const byId = new Map(inputs.eligible.map((e) => [e.stop.id, e]));
  const segments: SegmentPlan[] = [];
  if (first) segments.push({ kind: "prefix", stopIds: [first], start: inputs.origin, carriesBreak: false });
  if (middle.length > 0) {
    segments.push({
      kind: "main",
      stopIds: middle,
      start: first ? waypointFor(byId.get(first)!) : inputs.origin,
      end: last ? waypointFor(byId.get(last)!) : inputs.routeEnd,
      carriesBreak: true,
    });
  }
  if (last) {
    segments.push({
      kind: "suffix",
      stopIds: [last],
      start: middle.length > 0 ? waypointFor(byId.get(last)!) : first ? waypointFor(byId.get(first)!) : inputs.origin,
      end: inputs.routeEnd,
      carriesBreak: middle.length === 0,
    });
  }
  if (segments.length === 0) return [];
  if (!segments.some((s) => s.carriesBreak)) segments[segments.length - 1].carriesBreak = true;
  return segments;
}

export function solverTimeoutSeconds(shipments: number): number {
  if (shipments <= 20) return 10;
  if (shipments <= 100) return 20;
  return 40;
}

export interface BuiltRequest {
  request: OptimizeToursRequest;
  /** Stops whose constraints were already impossible at this segment's start (not sent). */
  preUnassigned: Array<{ stopId: string; code: string; message: string; suggestions: string[] }>;
  warnings: string[];
  shipmentStopIds: string[];
}

export function buildSegmentRequest(inputs: PlanInputs, segment: SegmentPlan, start: Waypoint, startTime: Date, label: string): BuiltRequest {
  const byId = new Map(inputs.eligible.map((e) => [e.stop.id, e]));
  const { costPerHour, costPerKilometer } = costs(inputs.objective);
  const warnings: string[] = [];
  const preUnassigned: BuiltRequest["preUnassigned"] = [];
  const shipments: ShipmentApi[] = [];
  const shipmentStopIds: string[] = [];

  let latestWindowEnd = startTime.getTime();
  for (const stopId of segment.stopIds) {
    const e = byId.get(stopId)!;
    const w = inputs.windows.get(stopId);
    const timeWindows: TimeWindowApi[] = [];
    if (w?.kind === "hard") {
      if (w.end.getTime() < startTime.getTime()) {
        preUnassigned.push({
          stopId,
          code: "time-window-closed",
          message: "This stop's delivery window closes before the route can reach it.",
          suggestions: ["Change the window to a later time.", "Change it to “Prefer to arrive by”.", "Leave earlier, or remove the stop from this route."],
        });
        continue;
      }
      const s = w.start && w.start.getTime() > startTime.getTime() ? w.start : startTime;
      timeWindows.push({ startTime: rfc3339(s), endTime: rfc3339(w.end) });
      latestWindowEnd = Math.max(latestWindowEnd, w.end.getTime());
    } else if (w?.kind === "softDeadline") {
      if (w.end.getTime() <= startTime.getTime()) {
        warnings.push("A preferred arrival time has already passed; that stop is planned without it.");
      } else {
        timeWindows.push({ softEndTime: rfc3339(w.end), costPerHourAfterSoftEndTime: costPerHour * 3 });
        latestWindowEnd = Math.max(latestWindowEnd, w.end.getTime());
      }
    }
    shipments.push({
      label: stopId,
      deliveries: [{ arrivalWaypoint: waypointFor(e), duration: duration(inputs.serviceSeconds(stopId)), ...(timeWindows.length ? { timeWindows } : {}) }],
    });
    shipmentStopIds.push(stopId);
  }

  const vehicle: VehicleApi = {
    label: "driver",
    travelMode: "DRIVING",
    startWaypoint: start,
    ...(segment.end ? { endWaypoint: segment.end } : {}),
    costPerHour,
    costPerKilometer,
    startTimeWindows: [{ startTime: rfc3339(startTime), endTime: rfc3339(startTime) }],
  };

  if (segment.carriesBreak && inputs.breakWindow) {
    const b = inputs.breakWindow;
    if (b.latest.getTime() < startTime.getTime()) {
      warnings.push("Your break window ends before this part of the route starts, so the break could not be planned. Adjust the break window.");
    } else {
      const earliest = b.earliest.getTime() < startTime.getTime() ? startTime : b.earliest;
      const breakRequest: BreakRequestApi = { earliestStartTime: rfc3339(earliest), latestStartTime: rfc3339(b.latest), minDuration: duration(b.durationSeconds) };
      vehicle.breakRule = { breakRequests: [breakRequest] };
      latestWindowEnd = Math.max(latestWindowEnd, b.latest.getTime() + b.durationSeconds * 1000);
    }
  }

  const globalEnd = new Date(Math.max(startTime.getTime() + 20 * 3600_000, latestWindowEnd + 3600_000));
  const request: OptimizeToursRequest = {
    timeout: duration(solverTimeoutSeconds(shipments.length)),
    model: {
      globalStartTime: rfc3339(startTime),
      globalEndTime: rfc3339(globalEnd),
      shipments,
      vehicles: [vehicle],
    },
    considerRoadTraffic: inputs.considerTraffic,
    populatePolylines: true,
    label,
  };
  return { request, preUnassigned, warnings, shipmentStopIds };
}

/**
 * Request that evaluates the driver's current order (sequence fixed, times computed) under the same
 * conditions, so savings can be shown honestly. Costs one extra billed request.
 */
export function buildBaselineRequest(inputs: PlanInputs, currentOrder: string[], label: string): BuiltRequest {
  const segment: SegmentPlan = { kind: "main", stopIds: currentOrder, start: inputs.origin, end: inputs.routeEnd, carriesBreak: true };
  const built = buildSegmentRequest(inputs, segment, inputs.origin, inputs.departure, label);
  built.request.injectedSolutionConstraint = {
    routes: [{ vehicleIndex: 0, visits: built.shipmentStopIds.map((_, i) => ({ shipmentIndex: i, isPickup: false as const })) }],
    constraintRelaxations: [{ relaxations: [{ level: "RELAX_VISIT_TIMES_AFTER_THRESHOLD", thresholdVisitCount: 0 }], vehicleIndices: [0] }],
  };
  return built;
}
