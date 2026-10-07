/**
 * `requestOptimization` core. Authenticated uid is passed in; every path is under users/{uid}, so a
 * caller can never read or modify another user's route (it simply does not exist for them).
 *
 * Guarantees:
 *  - Idempotent per client `requestId`; one active job per route (repeated taps never start a second
 *    paid request — they receive the running job).
 *  - Input revision checked before solving and again, transactionally, before the result is stored.
 *    A route edited mid-flight yields status `stale`; the edit is never overwritten.
 *  - Hard usage limits reserved before any paid call.
 *  - Every eligible stop is returned exactly once (visited or unassigned with an explanation);
 *    ineligible stops are listed with reasons. Provider inconsistencies are rejected.
 *  - Failures never touch the stop list or the currently applied plan.
 */
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { AppError, errors } from "../errors";
import { release, reserveOptimization, type Limits, type Reservation } from "../quota";
import type { TourOptimizer } from "../providers/interfaces";
import type { LocationTaskDoc, OriginInput, OutcomeDoc, PackageDoc, PlanMetricsOut, ProposalOut, RouteDoc, StopDoc } from "../types";
import { parseInput, RequestOptimizationInput } from "../validation";
import { evaluateEligibility, validPoint, type EligibleStop } from "./eligibility";
import type { OptimizeToursRequest, OptimizeToursResponse, Waypoint } from "./googleTypes";
import { interpretSegment, ProviderInconsistencyError, type SegmentResult } from "./interpret";
import { buildBaselineRequest, buildSegmentRequest, planSegments, solverTimeoutSeconds, waypointFor, type PlanInputs, type StopWindow } from "./model";
import { wallClockToInstant } from "./time";

export interface OptimizationDeps {
  db: Firestore;
  optimizer: TourOptimizer;
  limits: Limits;
  now: () => Date;
  /** Emulator test provider only: synthetic demo addresses may be optimized. */
  allowSynthetic: boolean;
  retryDelaysMs: number[];
  /** Tolerance between device-computed and server-computed instants (time-zone database drift). */
  timelineToleranceMs?: number;
}

export interface OptimizationResult {
  requestId: string;
  status: string;
  reused: boolean;
  error?: { reason: string; message: string; suggestions: string[] };
}

const PROPOSAL_LIFETIME_MS = 24 * 3600_000;
const LOCK_MS = 3 * 60_000;

export async function requestOptimization(deps: OptimizationDeps, uid: string, raw: unknown): Promise<OptimizationResult> {
  let input: RequestOptimizationInput;
  try {
    input = parseInput(RequestOptimizationInput, raw);
  } catch (e) {
    throw errors.invalidInput((e as Error).message);
  }
  const { db } = deps;
  const now = deps.now();
  const userRef = db.doc(`users/${uid}`);
  const jobRef = userRef.collection("optimizationRequests").doc(input.requestId);
  const lockRef = userRef.collection("optimizationLocks").doc(input.routeId);

  const start = await db.runTransaction(async (tx) => {
    const [job, lock] = await Promise.all([tx.get(jobRef), tx.get(lockRef)]);
    if (job.exists) return { kind: "existing" as const, job: job.data()! };
    const l = lock.data();
    if (l && l.until.toMillis() > now.getTime() && l.requestId !== input.requestId) return { kind: "busy" as const, requestId: l.requestId as string };
    tx.create(jobRef, {
      id: input.requestId,
      routeId: input.routeId,
      inputRevision: input.inputRevision,
      status: "queued",
      provider: deps.optimizer.provider,
      createdAt: Timestamp.fromDate(now),
      updatedAt: Timestamp.fromDate(now),
      expiresAt: Timestamp.fromMillis(now.getTime() + PROPOSAL_LIFETIME_MS),
      options: { origin: input.origin.kind, fixedNextStopId: input.fixedNextStopId ?? null, computeBaseline: input.computeBaseline, considerTraffic: input.considerTraffic, departNow: input.departNow },
    });
    tx.set(lockRef, { requestId: input.requestId, until: Timestamp.fromMillis(now.getTime() + LOCK_MS) });
    return { kind: "created" as const };
  });
  if (start.kind === "existing") return { requestId: input.requestId, status: start.job.status, reused: true, ...(start.job.error ? { error: start.job.error } : {}) };
  if (start.kind === "busy") return { requestId: start.requestId, status: "running", reused: true };

  let reservation: Reservation | undefined;
  let providerCalled = false;
  try {
    await jobRef.update({ status: "running", updatedAt: Timestamp.fromDate(deps.now()) });
    const outcome = await run(deps, uid, input, now, async (shipments) => {
      reservation = await reserveOptimization(db, uid, shipments, deps.limits, now);
    }, () => { providerCalled = true; });

    const status = await db.runTransaction(async (tx) => {
      const route = await tx.get(userRef.collection("routes").doc(input.routeId));
      if (!route.exists || (route.data() as RouteDoc).inputRevision !== input.inputRevision) {
        tx.update(jobRef, {
          status: "stale",
          updatedAt: Timestamp.fromDate(deps.now()),
          error: { reason: "route-changed", message: "The route changed while it was being optimized. Your edits were kept; recalculate to include them.", suggestions: ["Optimize again."] },
          billing: outcome.billing,
        });
        return "stale";
      }
      const s = outcome.proposal.status === "feasible" ? "succeeded" : "infeasible";
      tx.update(jobRef, { status: s, proposal: outcome.proposal, billing: outcome.billing, updatedAt: Timestamp.fromDate(deps.now()) });
      return s;
    });
    return { requestId: input.requestId, status, reused: false };
  } catch (e) {
    const appError = e instanceof AppError ? e
      : e instanceof ProviderInconsistencyError ? new AppError("internal", "provider-inconsistent", "The routing service returned an incomplete plan, so it was not used. Your current plan is unchanged.", ["Try again."], true)
      : new AppError("internal", "internal", "Optimization failed on the server. Your stops and current plan are unchanged.", ["Try again."], true);
    if (reservation && (!providerCalled || !appError.possiblyBilled) && appError.reason !== "provider-inconsistent") {
      await release(db, reservation).catch(() => undefined);
    }
    await jobRef.update({
      status: "failed",
      updatedAt: Timestamp.fromDate(deps.now()),
      error: { reason: appError.reason, message: appError.message, suggestions: appError.suggestions },
    }).catch(() => undefined);
    throw appError;
  } finally {
    await lockRef.delete().catch(() => undefined);
  }
}

interface RunOutput {
  proposal: ProposalOut;
  billing: { requests: number; shipmentsSubmitted: number; providerMillis: number };
}

async function run(
  deps: OptimizationDeps,
  uid: string,
  input: RequestOptimizationInput,
  now: Date,
  reserve: (shipments: number) => Promise<void>,
  markCalled: () => void,
): Promise<RunOutput> {
  const { db } = deps;
  const routeRef = db.doc(`users/${uid}/routes/${input.routeId}`);
  const routeSnap = await routeRef.get();
  if (!routeSnap.exists) throw errors.notFound("Route");
  const route = routeSnap.data() as RouteDoc;
  if (route.inputRevision > input.inputRevision) {
    throw new AppError("failed-precondition", "revision-behind", "This route was changed on another device. Refresh and optimize again.", ["Optimize again."]);
  }
  if (route.inputRevision < input.inputRevision) {
    throw new AppError("failed-precondition", "revision-ahead", "Your latest changes haven't reached the server yet. They will sync automatically — try again once they are saved.", ["Wait for changes to sync, then optimize again."]);
  }

  const [stopsSnap, packagesSnap, outcomesSnap, tasksSnap] = await Promise.all([
    routeRef.collection("stops").get(),
    routeRef.collection("packages").get(),
    routeRef.collection("outcomes").get(),
    routeRef.collection("tasks").get(),
  ]);
  const stops = stopsSnap.docs.map((d) => d.data() as StopDoc);
  const packages = packagesSnap.docs.map((d) => d.data() as PackageDoc);
  const outcomes = outcomesSnap.docs.map((d) => d.data() as OutcomeDoc);
  const tasks = tasksSnap.docs.map((doc) => {
    const data = doc.data();
    if (!readableTask(data, doc.id)) {
      throw new AppError("failed-precondition", "unsupported-work", "Some required work cannot be interpreted safely, so this route cannot be optimized.", ["Update the app or repair the affected work before optimizing."]);
    }
    return data;
  });

  const eligibility = evaluateEligibility(stops, packages, outcomes, now, deps.allowSynthetic, tasks);
  const stopIds = new Set(stops.map((stop) => stop.id));
  if (eligibility.excluded.some((stop) => stop.reason === "unsupportedTasks")
    || tasks.some((task) => task.required && !stopIds.has(task.stopID))) {
    throw new AppError("failed-precondition", "unsupported-work", "Some required work cannot be interpreted safely, so this route cannot be optimized.", ["Update the app or repair the affected work before optimizing."]);
  }
  if (eligibility.eligible.length === 0) {
    throw new AppError("failed-precondition", "no-eligible-stops", "There are no verified stops with required work left to plan.", ["Review stops that need address verification.", "Retry deferred work to include it.", "Update the app if a stop has unsupported work."]);
  }
  if (eligibility.eligible.length > deps.limits.maxEligibleStops) {
    throw new AppError("failed-precondition", "too-many-stops", `This route has ${eligibility.eligible.length} stops ready to plan; the limit is ${deps.limits.maxEligibleStops} per optimization.`, ["Split the route into two routes."]);
  }

  const origin = originWaypoint(input.origin, route, stops, now);
  const routeEnd = route.returnToStart ? placeWaypoint(route.start, now) : placeWaypoint(route.end, now);
  if (route.latestArrivalMinute !== undefined && !routeEnd) {
    throw new AppError("failed-precondition", "missing-end", "Set a verified warehouse location before planning a latest arrival time.", ["Set Start to your warehouse and enable Return to start, or choose an End location."]);
  }
  const warnings: string[] = [];
  const { departure, latestArrival, windows, breakWindow } = checkTimeline(input, route, eligibility.eligible, now, deps.timelineToleranceMs ?? 2 * 3600_000, warnings);

  const firstStopId = input.fixedNextStopId && eligibility.eligible.some((e) => e.stop.id === input.fixedNextStopId)
    ? input.fixedNextStopId
    : eligibility.eligible.find((e) => e.stop.pin === "first")?.stop.id;
  const lastStopId = eligibility.eligible.find((e) => e.stop.pin === "last" && e.stop.id !== firstStopId)?.stop.id;
  const serviceById = new Map(eligibility.eligible.map((e) => [e.stop.id, e.stop.serviceSeconds ?? route.defaultServiceSeconds]));
  const inputs: PlanInputs = {
    eligible: eligibility.eligible,
    serviceSeconds: (id) => serviceById.get(id) ?? route.defaultServiceSeconds,
    windows,
    origin,
    routeEnd,
    departure,
    latestArrival,
    breakWindow,
    firstStopId,
    lastStopId,
    objective: route.objective === "fastest" ? "fastest" : "balanced",
    considerTraffic: input.considerTraffic,
  };

  const segments = planSegments(inputs);
  const shipments = eligibility.eligible.length + (input.computeBaseline ? eligibility.eligible.length : 0);
  await reserve(shipments);

  const softDeadline = (id: string) => (windows.get(id)?.kind === "softDeadline" ? windows.get(id)!.end : undefined);
  const byId = new Map(eligibility.eligible.map((e) => [e.stop.id, e]));
  const results: SegmentResult[] = [];
  const unassigned: ProposalOut["unassigned"] = [];
  let requests = 0, submitted = 0, providerMillis = 0;
  let cursorTime = departure;
  let cursorPlace: Waypoint = origin;

  const call = async (req: OptimizeToursRequest): Promise<OptimizeToursResponse> => {
    requests += 1;
    submitted += req.model.shipments.length;
    const t0 = Date.now();
    try {
      return await withRetries(() => { markCalled(); return deps.optimizer.optimizeTours(req, (solverTimeoutSeconds(req.model.shipments.length) + 25) * 1000); }, deps.retryDelaysMs);
    } finally {
      providerMillis += Date.now() - t0;
    }
  };

  for (const segment of segments) {
    let startPlace = cursorPlace;
    if (segment.kind === "main" && firstStopId && results.length > 0 && results[0].visits.length === 0) startPlace = origin;
    const built = buildSegmentRequest(inputs, segment, startPlace, cursorTime, `${input.requestId}:${segment.kind}`);
    warnings.push(...built.warnings);
    unassigned.push(...built.preUnassigned);
    if (built.shipmentStopIds.length === 0) continue;
    const response = await call(built.request);
    const result = interpretSegment(response, built.shipmentStopIds, inputs.serviceSeconds, softDeadline, cursorTime);
    if (latestArrival && result.end > latestArrival) throw new ProviderInconsistencyError("the plan exceeds the latest arrival time");
    results.push(result);
    unassigned.push(...result.unassigned);
    cursorTime = result.end;
    const lastVisited = result.visits[result.visits.length - 1]?.stopId;
    cursorPlace = segment.end ?? (lastVisited ? waypointFor(byId.get(lastVisited)!) : startPlace);
    if (segment.kind === "main" && lastStopId) cursorPlace = waypointFor(byId.get(lastStopId)!);
  }
  if (lastStopId && unassigned.some((u) => u.stopId === lastStopId) && segments.some((s) => s.kind === "main")) {
    warnings.push("The stop pinned last could not be scheduled; the planned route still ends at its location. Review that stop.");
  }

  let baseline: PlanMetricsOut | null = null;
  let baselineNote: string | null = null;
  if (input.computeBaseline) {
    try {
      const order = eligibility.eligible.map((e) => e.stop.id);
      const built = buildBaselineRequest(inputs, order, `${input.requestId}:baseline`);
      const response = await call(built.request);
      const r = interpretSegment(response, built.shipmentStopIds, inputs.serviceSeconds, softDeadline, departure);
      if (r.unassigned.length > 0 || built.preUnassigned.length > 0 || (latestArrival && r.end > latestArrival)) {
        baselineNote = "Your current order can't meet every time constraint, so no savings comparison is shown.";
      } else {
        baseline = metricsOut(departure, r.end, [r]);
      }
    } catch {
      baselineNote = "The comparison with your current order could not be calculated.";
    }
  }

  const visits = results.flatMap((r) => r.visits);
  if (latestArrival && unassigned.length > 0) warnings.push("Some stops could not be scheduled with your latest arrival time and other constraints. Leave earlier, allow a later return, or move stops to another route. Unassigned stops remain on your route.");
  const end = results.length ? results[results.length - 1].end : departure;
  const proposal: ProposalOut = {
    requestId: input.requestId,
    routeId: input.routeId,
    inputRevision: input.inputRevision,
    provider: deps.optimizer.provider,
    status: unassigned.length === 0 ? "feasible" : "infeasible",
    calculatedAt: Timestamp.fromDate(now),
    expiresAt: Timestamp.fromMillis(now.getTime() + PROPOSAL_LIFETIME_MS),
    trafficConsidered: input.considerTraffic && deps.optimizer.provider === "google",
    origin: input.origin as OriginInput,
    fixedNextStopId: input.fixedNextStopId ?? null,
    visits: visits.map((v) => ({
      stopId: v.stopId,
      arrival: Timestamp.fromDate(v.arrival),
      start: Timestamp.fromDate(v.start),
      departure: Timestamp.fromDate(v.departure),
      ...(v.lateBySeconds ? { lateBySeconds: v.lateBySeconds } : {}),
    })),
    unassigned,
    excluded: eligibility.excluded,
    breaks: results.flatMap((r) => r.breaks).map((b) => ({ start: Timestamp.fromDate(b.start), durationSeconds: b.durationSeconds })),
    metrics: results.length ? metricsOut(departure, end, results) : null,
    baseline,
    baselineNote,
    polylines: results.map((r) => r.polyline).filter((p): p is string => !!p),
    completedStopIdsAtRequest: eligibility.completedStopIds,
    warnings,
  };

  // Independent check: every eligible stop exactly once.
  const accounted = new Map<string, number>();
  for (const v of proposal.visits) accounted.set(v.stopId, (accounted.get(v.stopId) ?? 0) + 1);
  for (const u of proposal.unassigned) accounted.set(u.stopId, (accounted.get(u.stopId) ?? 0) + 1);
  for (const e of eligibility.eligible) {
    if (accounted.get(e.stop.id) !== 1) throw new ProviderInconsistencyError("eligible stop not accounted for exactly once");
  }

  return { proposal, billing: { requests, shipmentsSubmitted: submitted, providerMillis } };
}

function metricsOut(departure: Date, end: Date, results: SegmentResult[]): PlanMetricsOut {
  return {
    routeStart: Timestamp.fromDate(departure),
    routeEnd: Timestamp.fromDate(end),
    travelSeconds: Math.round(results.reduce((a, r) => a + r.travelSeconds, 0)),
    travelMeters: Math.round(results.reduce((a, r) => a + r.travelMeters, 0)),
    serviceSeconds: Math.round(results.reduce((a, r) => a + r.serviceSeconds, 0)),
    waitSeconds: Math.round(results.reduce((a, r) => a + r.waitSeconds, 0)),
    breakSeconds: Math.round(results.reduce((a, r) => a + r.breakSeconds, 0)),
  };
}

export async function withRetries<T>(fn: () => Promise<T>, delaysMs: number[]): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      // Retry only transient errors where the provider certainly did not bill (no timeouts, no quota).
      const retryable = e instanceof AppError && e.code === "unavailable" && !e.possiblyBilled;
      if (!retryable || attempt >= delaysMs.length) throw e;
      await new Promise((r) => setTimeout(r, delaysMs[attempt]));
    }
  }
}

function placeWaypoint(place: RouteDoc["start"], now: Date): Waypoint | undefined {
  if (!place) return undefined;
  const l = place.located;
  if (l && validPoint(l.point) && (l.expiresAt ? l.expiresAt.toMillis() > now.getTime() : l.source !== "providerGeocode")) {
    return { location: { latLng: { latitude: l.point.latitude, longitude: l.point.longitude } } };
  }
  return place.placeID ? { placeId: place.placeID } : undefined;
}

function originWaypoint(origin: OriginInput, route: RouteDoc, stops: StopDoc[], now: Date): Waypoint {
  switch (origin.kind) {
    case "currentLocation":
      return { location: { latLng: { latitude: origin.latitude, longitude: origin.longitude } } };
    case "stop": {
      const stop = stops.find((s) => s.id === origin.stopId);
      const w = stop ? placeWaypoint({ label: "", located: stop.resolution?.located, placeID: stop.resolution?.placeID }, now) : undefined;
      if (!w) throw new AppError("failed-precondition", "missing-origin", "The selected starting stop has no usable location.", ["Choose another starting point."]);
      return w;
    }
    case "routeStart": {
      const w = placeWaypoint(route.start, now);
      if (!w) throw new AppError("failed-precondition", "missing-origin", "Set a start location (or use your current location) before optimizing.", ["Add a start location in route settings.", "Optimize from your current location."]);
      return w;
    }
  }
}

/** A malformed required flag must never make persisted work disappear from optimizer input. */
function readableTask(value: unknown, documentId: string): value is LocationTaskDoc {
  if (!value || typeof value !== "object") return false;
  const task = value as Record<string, unknown>;
  return task.id === documentId && typeof task.id === "string" && task.id.length > 0
    && typeof task.stopID === "string" && task.stopID.length > 0
    && typeof task.kind === "string" && task.kind.length > 0
    && typeof task.required === "boolean"
    && Number.isInteger(task.schemaVersion)
    && typeof task.title === "string" && typeof task.instructions === "string"
    && Number.isInteger(task.orderRank)
    && task.createdAt instanceof Timestamp && task.updatedAt instanceof Timestamp
    && (task.packageID === undefined || (typeof task.packageID === "string" && task.packageID.length > 0));
}

function checkTimeline(input: RequestOptimizationInput, route: RouteDoc, eligible: EligibleStop[], now: Date, toleranceMs: number, warnings: string[]): { departure: Date; latestArrival?: Date; windows: Map<string, StopWindow>; breakWindow?: PlanInputs["breakWindow"] } {
  const tz = route.timeZoneID;
  let drift = false;
  const check = (client: string, minute: number, what: string): Date => {
    const device = new Date(client);
    const server = wallClockToInstant(route.serviceDate, minute, tz).date;
    const diff = Math.abs(device.getTime() - server.getTime());
    if (diff > toleranceMs) throw errors.invalidInput(`${what} does not match the route's time zone`);
    if (diff !== 0) drift = true;
    return device;
  };
  let departure: Date;
  try {
    departure = check(input.timeline.departure, route.departureMinute, "departure");
  } catch (e) {
    if (e instanceof AppError) throw e;
    throw errors.invalidInput("route time settings are invalid");
  }
  if (input.departNow) departure = new Date(Math.max(now.getTime(), departure.getTime()));
  let latestArrival: Date | undefined;
  if (route.latestArrivalMinute !== undefined) {
    if (!Number.isInteger(route.latestArrivalMinute) || route.latestArrivalMinute <= route.departureMinute || route.latestArrivalMinute >= 2880) throw errors.invalidInput("the latest arrival time must be after departure and within the route's two-day time range");
    if (!input.timeline.latestArrival) throw errors.invalidInput("the latest arrival time is missing; refresh and try again");
    latestArrival = check(input.timeline.latestArrival, route.latestArrivalMinute, "the latest arrival time");
    if (latestArrival <= departure) throw new AppError("failed-precondition", "arrival-deadline-passed", "The latest arrival time is already past or before departure.", ["Set a later arrival time or change the route date."]);
  } else if (input.timeline.latestArrival) {
    throw errors.invalidInput("the latest arrival time does not match the route; refresh and try again");
  }

  const windows = new Map<string, StopWindow>();
  for (const e of eligible) {
    const w = e.stop.timeWindow;
    const sent = input.timeline.windows[e.stop.id];
    if (!w && !sent) continue;
    if (!w || !sent) throw errors.invalidInput("stop time windows do not match the route; refresh and try again");
    const end = check(sent.end, w.endMinute, "a time window");
    if (w.kind === "hard") {
      if (w.startMinute === undefined || !sent.start) throw errors.invalidInput("a hard time window has no start");
      const start = check(sent.start, w.startMinute, "a time window");
      if (start.getTime() >= end.getTime()) throw errors.invalidInput("a time window ends before it starts");
      windows.set(e.stop.id, { kind: "hard", start, end });
    } else {
      windows.set(e.stop.id, { kind: "softDeadline", end });
    }
  }
  let breakWindow: PlanInputs["breakWindow"];
  if (route.breakRule) {
    const b = input.timeline.breakWindow;
    if (!b) throw errors.invalidInput("the break window is missing");
    breakWindow = {
      earliest: check(b.earliest, route.breakRule.earliestStartMinute, "the break window"),
      latest: check(b.latest, route.breakRule.latestStartMinute, "the break window"),
      durationSeconds: route.breakRule.durationSeconds,
    };
  }
  if (drift) warnings.push("This device and the server use different time-zone rules for this route's zone. Times follow your device.");
  return { departure, latestArrival, windows, breakWindow };
}
