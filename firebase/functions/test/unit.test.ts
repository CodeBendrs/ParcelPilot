import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Timestamp } from "firebase-admin/firestore";
import { describe, expect, it } from "vitest";
import { assertMayUsePaidFeatures } from "../src/accountChecks";
import { AppError, errors } from "../src/errors";
import { deliveryTaskId, evaluateEligibility, packageStatuses, workStatuses } from "../src/optimization/eligibility";
import type { OptimizeToursResponse } from "../src/optimization/googleTypes";
import { interpretSegment, ProviderInconsistencyError } from "../src/optimization/interpret";
import { buildBaselineRequest, buildSegmentRequest, planSegments, type PlanInputs } from "../src/optimization/model";
import { withRetries } from "../src/optimization/run";
import { parseDuration, wallClockToInstant, rfc3339 } from "../src/optimization/time";
import { FakeGeocoder, FakeSuggester, FakeTourOptimizer } from "../src/providers/fake";
import { buildAutocompleteBody, mapPlacePrediction, mapV4Result } from "../src/providers/google";
import { parseInput, RequestOptimizationInput, ResolveAddressInput, SuggestAddressesInput } from "../src/validation";
import type { LocationTaskDoc, OutcomeDoc } from "../src/types";
import { outcomeDoc, packageDoc, routeDoc, stopDoc, T0 } from "./helpers";

function taskDoc(id: string, stopID = "s1", extra: Partial<LocationTaskDoc> = {}): LocationTaskDoc {
  return { id, schemaVersion: 1, stopID, kind: "pickup", required: true, title: "Collect return", instructions: "", orderRank: 0, createdAt: Timestamp.fromDate(T0), updatedAt: Timestamp.fromDate(T0), ...extra };
}

function taskOutcome(id: string, taskID: string, kind: OutcomeDoc["kind"], extra: Partial<OutcomeDoc> = {}): OutcomeDoc {
  return { id, schemaVersion: 2, taskID, stopID: "s1", kind, recordedAt: Timestamp.fromDate(T0), photoIDs: [], ...extra };
}

describe("generalized required work eligibility", () => {
  it("includes pickup-only and required checklist stops while ignoring optional-only work", () => {
    const tasks = [taskDoc("pickup"), taskDoc("check", "s2", { kind: "checklist" }), taskDoc("optional", "s3", { required: false })];
    const result = evaluateEligibility([stopDoc(1), stopDoc(2), stopDoc(3)], [], [], T0, false, tasks);
    expect(result.eligible.map((item) => item.stop.id)).toEqual(["s1", "s2"]);
    expect(result.excluded).toEqual([{ stopId: "s3", reason: "noPendingPackages" }]);
  });

  it("keeps a partially delivered location eligible when its required pickup remains", () => {
    const packages = [packageDoc(1, "s1"), packageDoc(2, "s1")];
    const outcomes = [outcomeDoc("a", "p1", "s1", "delivered", T0.getTime()), outcomeDoc("b", "p2", "s1", "delivered", T0.getTime())];
    const tasks = [taskDoc("pickup")];
    expect(evaluateEligibility([stopDoc(1)], packages, outcomes, T0, false, tasks).eligible).toHaveLength(1);
    const complete = evaluateEligibility([stopDoc(1)], packages, [...outcomes, taskOutcome("c", "pickup", "completed")], T0, false, tasks);
    expect(complete.completedStopIds).toEqual(["s1"]);
  });

  it("failure is handled unsuccessfully and Retry restores actionable work", () => {
    const tasks = [taskDoc("pickup")];
    const failed = taskOutcome("a", "pickup", "failed", { reason: "businessClosed" });
    expect(workStatuses([], tasks, [failed]).get("pickup")).toBe("failed");
    expect(evaluateEligibility([stopDoc(1)], [], [failed], T0, false, tasks).completedStopIds).toEqual(["s1"]);
    const retried = [...[failed], taskOutcome("b", "pickup", "requeued")];
    expect(workStatuses([], tasks, retried).get("pickup")).toBe("pending");
    expect(evaluateEligibility([stopDoc(1)], [], retried, T0, false, tasks).eligible).toHaveLength(1);
  });

  it("deferral removes a remaining visit until Retry; Undo restores the deferred state", () => {
    const tasks = [taskDoc("check", "s1", { kind: "checklist" })];
    const deferred = taskOutcome("a", "check", "skipped");
    const retry = taskOutcome("b", "check", "requeued");
    expect(evaluateEligibility([stopDoc(1)], [], [deferred], T0, false, tasks).excluded).toEqual([{ stopId: "s1", reason: "onlySkippedPackages" }]);
    expect(evaluateEligibility([stopDoc(1)], [], [deferred, retry], T0, false, tasks).eligible).toHaveLength(1);
    expect(workStatuses([], tasks, [deferred, { ...retry, voidedAt: Timestamp.fromMillis(T0.getTime() + 1000) }]).get("check")).toBe("deferred");
  });

  it("optional pending or deferred work does not block a handled required checklist", () => {
    const tasks = [taskDoc("required", "s1", { kind: "checklist" }), taskDoc("optional", "s1", { required: false })];
    const outcomes = [taskOutcome("a", "required", "completed"), taskOutcome("b", "optional", "skipped")];
    expect(evaluateEligibility([stopDoc(1)], [], outcomes, T0, false, tasks).completedStopIds).toEqual(["s1"]);
  });

  it("Retry of one mixed required task preserves the other task's completion", () => {
    const tasks = [taskDoc("pickup")];
    const outcomes = [outcomeDoc("a", "p1", "s1", "delivered", T0.getTime()), taskOutcome("b", "pickup", "skipped"), taskOutcome("c", "pickup", "requeued")];
    const statuses = workStatuses([packageDoc(1)], tasks, outcomes);
    expect(statuses.get(deliveryTaskId("p1"))).toBe("completed");
    expect(statuses.get("pickup")).toBe("pending");
  });

  it("Undo of completion makes a pickup eligible again without mutating its definition", () => {
    const tasks = [taskDoc("pickup")];
    const event = taskOutcome("a", "pickup", "completed", { voidedAt: Timestamp.fromMillis(T0.getTime() + 1000) });
    expect(workStatuses([], tasks, [event]).get("pickup")).toBe("pending");
    expect(evaluateEligibility([stopDoc(1)], [], [event], T0, false, tasks).eligible).toHaveLength(1);
  });

  it.each([{ kind: "future-work" }, { schemaVersion: 99 }, { kind: "delivery" }])("fails closed for unsupported required definitions: %j", (extra) => {
    const tasks = [taskDoc("unknown", "s1", extra)];
    expect(workStatuses([], tasks, []).get("unknown")).toBe("unsupported");
    expect(evaluateEligibility([stopDoc(1)], [], [], T0, false, tasks).excluded).toEqual([{ stopId: "s1", reason: "unsupportedTasks" }]);
  });

  it("a persisted definition cannot shadow a delivery projection even if optional", () => {
    const tasks = [taskDoc(deliveryTaskId("p1"), "s1", { required: false })];
    expect(evaluateEligibility([stopDoc(1)], [packageDoc(1)], [], T0, false, tasks).excluded).toEqual([{ stopId: "s1", reason: "unsupportedTasks" }]);
  });

  it("same raw package and standalone task IDs remain independent and units stay separate", () => {
    const tasks = [taskDoc("p1", "s2", { packageID: "p2" })];
    const statuses = workStatuses([packageDoc(1), packageDoc(2)], tasks, [taskOutcome("a", "p1", "completed", { stopID: "s2" })]);
    expect(statuses.get("p1")).toBe("completed");
    expect(statuses.get(deliveryTaskId("p1"))).toBe("pending");
    expect(evaluateEligibility([stopDoc(1), stopDoc(2)], [packageDoc(1), packageDoc(2)], [], T0, false, tasks).eligible.map((item) => item.stop.id)).toEqual(["s1", "s2"]);
  });

  it("schema 2 delivery outcomes require the matching package identity and valid disposition", () => {
    const good = taskOutcome("a", deliveryTaskId("p1"), "delivered", { packageID: "p1" });
    expect(workStatuses([packageDoc(1)], [], [good]).get(deliveryTaskId("p1"))).toBe("completed");
    for (const bad of [{ ...good, packageID: undefined }, { ...good, kind: "completed" as const }, { ...good, stopID: "s2" }]) {
      expect(workStatuses([packageDoc(1)], [], [bad]).get(deliveryTaskId("p1"))).toBe("unsupported");
    }
  });

  it("invalid identity cannot be hidden by voiding or a later valid completion", () => {
    const tasks = [taskDoc("pickup")];
    const bad = taskOutcome("a", "pickup", "delivered", { voidedAt: Timestamp.fromDate(T0) });
    expect(workStatuses([], tasks, [bad, taskOutcome("b", "pickup", "completed")]).get("pickup")).toBe("unsupported");
  });

  it("unknown generalized targets cannot bypass validation for a package they still claim", () => {
    const wrongTask = taskOutcome("a", "missing-task", "delivered", { packageID: "p1" });
    expect(workStatuses([packageDoc(1)], [], [wrongTask]).get(deliveryTaskId("p1"))).toBe("unsupported");
    expect(evaluateEligibility([stopDoc(1)], [packageDoc(1)], [wrongTask], T0, false).excluded).toEqual([{ stopId: "s1", reason: "unsupportedTasks" }]);
    const oldHistory = [outcomeDoc("old-package", "removed-package", "s1", "delivered", T0.getTime()), taskOutcome("old-task", "removed-task", "completed")];
    expect(evaluateEligibility([stopDoc(1)], [packageDoc(1)], oldHistory, T0, false).eligible).toHaveLength(1);
  });

  it("same immutable event merges voiding and lexical timestamp ties deterministically", () => {
    const tasks = [taskDoc("pickup")];
    const complete = taskOutcome("a", "pickup", "completed");
    const voided = { ...complete, voidedAt: Timestamp.fromMillis(T0.getTime() + 1000) };
    for (const events of [[complete, voided], [voided, complete], [complete, complete, voided]]) expect(workStatuses([], tasks, events).get("pickup")).toBe("pending");
    const deferred = taskOutcome("z", "pickup", "skipped");
    expect(workStatuses([], tasks, [complete, deferred]).get("pickup")).toBe("deferred");
    expect(workStatuses([], tasks, [deferred, complete]).get("pickup")).toBe("deferred");
  });

  it("conflicting payloads under one event ID fail closed for every affected task", () => {
    const tasks = [taskDoc("one"), taskDoc("two")];
    const a = taskOutcome("same", "one", "completed");
    const b = taskOutcome("same", "two", "completed");
    for (const events of [[a, b], [b, a]]) expect([...workStatuses([], tasks, events).values()]).toEqual(["unsupported", "unsupported"]);
  });
});

describe("time zones (shared fixture with the iOS app)", () => {
  const fixture = JSON.parse(readFileSync(join(__dirname, "../../../fixtures/shared/timezone-cases.json"), "utf8")) as { cases: Array<{ name: string; timeZone: string; serviceDate: string; minute: number; expectedUTC: string; resolution: string }> };

  it.each(fixture.cases.map((c) => [c.name, c] as const))("%s", (_, c) => {
    const r = wallClockToInstant(c.serviceDate, c.minute, c.timeZone);
    expect(rfc3339(r.date)).toBe(c.expectedUTC);
    expect(r.resolution).toBe(c.resolution);
  });

  it("rejects impossible dates and zones", () => {
    expect(() => wallClockToInstant("2026-02-30", 0, "America/Toronto")).toThrow();
    expect(() => wallClockToInstant("2026-10-05", 0, "Mars/Base")).toThrow();
  });

  it("parses protobuf durations", () => {
    expect(parseDuration("123s")).toBe(123);
    expect(parseDuration("1.5s")).toBe(1.5);
    expect(parseDuration(undefined)).toBe(0);
  });
});

function inputs(stops = [stopDoc(1), stopDoc(2), stopDoc(3), stopDoc(4)], extra: Partial<PlanInputs> = {}): PlanInputs {
  return {
    eligible: stops.map((s) => ({ stop: s, location: s.resolution!.located!.point })),
    serviceSeconds: () => 120,
    windows: new Map(),
    origin: { location: { latLng: { latitude: 48.4284, longitude: -123.3656 } } },
    routeEnd: { location: { latLng: { latitude: 48.4284, longitude: -123.3656 } } },
    departure: new Date("2026-10-05T15:00:00Z"),
    objective: "balanced",
    considerTraffic: true,
    ...extra,
  };
}

describe("request building", () => {
  it("enforces latest arrival on every pinned segment and the baseline, including a next-day limit", () => {
    const latestArrival = new Date("2026-10-07T05:00:00Z");
    const i = inputs(undefined, { latestArrival, firstStopId: "s3", lastStopId: "s1" });
    for (const segment of planSegments(i)) {
      const built = buildSegmentRequest(i, segment, i.origin, i.departure, "req");
      expect(built.request.model.vehicles[0].endTimeWindows).toEqual([{ endTime: rfc3339(latestArrival) }]);
      expect(Date.parse(built.request.model.globalEndTime)).toBeGreaterThanOrEqual(latestArrival.getTime());
    }
    expect(buildBaselineRequest(i, ["s1", "s2", "s3", "s4"], "base").request.model.vehicles[0].endTimeWindows).toEqual([{ endTime: rfc3339(latestArrival) }]);
    const expired = buildSegmentRequest(i, planSegments(i)[2], i.origin, latestArrival, "expired");
    expect(expired.shipmentStopIds).toEqual([]);
    expect(expired.preUnassigned[0].code).toBe("arrival-deadline-conflict");
  });

  it("the fake solver counts service and the return drive rather than just the final delivery arrival", async () => {
    const i = inputs([stopDoc(1)], { latestArrival: new Date("2026-10-05T15:10:00Z"), serviceSeconds: () => 600 });
    const built = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    const response = await new FakeTourOptimizer().optimizeTours(built.request);
    expect(response.routes?.[0].visits).toHaveLength(0);
    expect(response.skippedShipments).toHaveLength(1);
    expect(Date.parse(response.routes![0].vehicleEndTime!)).toBeLessThanOrEqual(i.latestArrival!.getTime());
  });

  it("makes every shipment mandatory with a non-zero objective", () => {
    const i = inputs();
    const [segment] = planSegments(i);
    const { request } = buildSegmentRequest(i, segment, i.origin, i.departure, "req");
    expect(request.model.shipments).toHaveLength(4);
    for (const s of request.model.shipments) expect(s).not.toHaveProperty("penaltyCost");
    const v = request.model.vehicles[0];
    expect(v.costPerHour).toBeGreaterThan(0);
    expect(v.costPerKilometer).toBeGreaterThan(0);
    expect(v.endWaypoint).toBeDefined();
    expect(v.startTimeWindows?.[0]).toEqual({ startTime: "2026-10-05T15:00:00Z", endTime: "2026-10-05T15:00:00Z" });
    expect(request.considerRoadTraffic).toBe(true);
    expect(request.populatePolylines).toBe(true);
    expect(request.model.shipments[0].deliveries[0].duration).toBe("120s");
  });

  it("maps hard windows and soft deadlines to their precise API fields", () => {
    const windows = new Map([
      ["s1", { kind: "hard" as const, start: new Date("2026-10-05T16:00:00Z"), end: new Date("2026-10-05T17:00:00Z") }],
      ["s2", { kind: "softDeadline" as const, end: new Date("2026-10-05T18:00:00Z") }],
    ]);
    const i = inputs(undefined, { windows });
    const { request } = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    const byLabel = Object.fromEntries(request.model.shipments.map((s) => [s.label, s.deliveries[0].timeWindows]));
    expect(byLabel.s1).toEqual([{ startTime: "2026-10-05T16:00:00Z", endTime: "2026-10-05T17:00:00Z" }]);
    expect(byLabel.s2?.[0].softEndTime).toBe("2026-10-05T18:00:00Z");
    expect(byLabel.s2?.[0].costPerHourAfterSoftEndTime).toBeGreaterThan(0);
    expect(byLabel.s2?.[0].endTime).toBeUndefined();
    expect(byLabel.s3).toBeUndefined();
  });

  it("reports windows that already closed instead of sending or dropping them", () => {
    const windows = new Map([["s1", { kind: "hard" as const, start: new Date("2026-10-05T10:00:00Z"), end: new Date("2026-10-05T11:00:00Z") }]]);
    const i = inputs(undefined, { windows });
    const built = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    expect(built.shipmentStopIds).not.toContain("s1");
    expect(built.preUnassigned).toEqual([expect.objectContaining({ stopId: "s1", code: "time-window-closed" })]);
  });

  it("enforces first/last pins and the fixed next stop structurally (segments)", () => {
    const i = inputs(undefined, { firstStopId: "s3", lastStopId: "s1" });
    const segments = planSegments(i);
    expect(segments.map((s) => s.kind)).toEqual(["prefix", "main", "suffix"]);
    expect(segments[0].stopIds).toEqual(["s3"]);
    expect(segments[1].stopIds.sort()).toEqual(["s2", "s4"]);
    expect(segments[1].end).toEqual({ location: { latLng: i.eligible[0].location } }); // main ends at the last stop
    expect(segments[2].stopIds).toEqual(["s1"]);
    expect(segments[2].end).toEqual(i.routeEnd);
    expect(segments.filter((s) => s.carriesBreak)).toHaveLength(1);
  });

  it("adds the break only to the segment carrying it and clamps it to the segment start", () => {
    const i = inputs(undefined, { breakWindow: { earliest: new Date("2026-10-05T14:00:00Z"), latest: new Date("2026-10-05T20:00:00Z"), durationSeconds: 1800 } });
    const { request } = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    expect(request.model.vehicles[0].breakRule?.breakRequests[0]).toEqual({ earliestStartTime: "2026-10-05T15:00:00Z", latestStartTime: "2026-10-05T20:00:00Z", minDuration: "1800s" });
  });

  it("uses the place ID when coordinates have expired", () => {
    const s = stopDoc(1);
    const i = inputs([s]);
    i.eligible[0] = { stop: s, placeId: "place-1" };
    const { request } = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    expect(request.model.shipments[0].deliveries[0].arrivalWaypoint).toEqual({ placeId: "place-1" });
  });

  it("builds a baseline that fixes the current sequence and relaxes only times", () => {
    const i = inputs();
    const built = buildBaselineRequest(i, ["s4", "s3", "s2", "s1"], "base");
    expect(built.request.model.shipments.map((s) => s.label)).toEqual(["s4", "s3", "s2", "s1"]);
    expect(built.request.injectedSolutionConstraint?.routes[0].visits.map((v) => v.shipmentIndex)).toEqual([0, 1, 2, 3]);
    expect(built.request.injectedSolutionConstraint?.constraintRelaxations[0].relaxations[0].level).toBe("RELAX_VISIT_TIMES_AFTER_THRESHOLD");
  });

  it("scales the solver timeout with size", () => {
    const many = Array.from({ length: 150 }, (_, k) => stopDoc(k + 1));
    const i = inputs(many);
    const { request } = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    expect(request.timeout).toBe("40s");
  });
});

describe("response interpretation and verification", () => {
  const ids = ["s1", "s2", "s3"];
  const start = new Date("2026-10-05T15:00:00Z");
  const ok: OptimizeToursResponse = {
    routes: [{
      vehicleStartTime: "2026-10-05T15:00:00Z",
      vehicleEndTime: "2026-10-05T16:00:00Z",
      visits: [
        { shipmentIndex: 2, startTime: "2026-10-05T15:10:00Z", shipmentLabel: "s3" },
        { startTime: "2026-10-05T15:30:00Z", shipmentLabel: "s1" }, // shipmentIndex 0 omitted (proto3 default)
      ],
      transitions: [
        { travelDuration: "600s", travelDistanceMeters: 4000 },
        { travelDuration: "300s", travelDistanceMeters: 2000, waitDuration: "780s" },
        { travelDuration: "600s", travelDistanceMeters: 5000 },
      ],
      routePolyline: { points: "abc" },
    }],
    skippedShipments: [{ index: 1, label: "s2", reasons: [{ code: "CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TIME_WINDOWS" }] }],
  };

  it("maps visits, waits, skipped stops and totals", () => {
    const r = interpretSegment(ok, ids, () => 120, () => undefined, start);
    expect(r.visits.map((v) => v.stopId)).toEqual(["s3", "s1"]);
    expect(r.visits[1].arrival.toISOString()).toBe("2026-10-05T15:17:00.000Z");
    expect(r.visits[1].departure.toISOString()).toBe("2026-10-05T15:32:00.000Z");
    expect(r.unassigned).toEqual([expect.objectContaining({ stopId: "s2", code: "CANNOT_BE_PERFORMED_WITHIN_VEHICLE_TIME_WINDOWS" })]);
    expect(r.unassigned[0].suggestions.length).toBeGreaterThan(0);
    expect(r.travelMeters).toBe(11000);
    expect(r.polyline).toBe("abc");
  });

  it("rejects results where a stop is missing or duplicated", () => {
    const missing = { ...ok, skippedShipments: [] };
    expect(() => interpretSegment(missing, ids, () => 120, () => undefined, start)).toThrow(ProviderInconsistencyError);
    const dup = { routes: [{ ...ok.routes![0], visits: [...ok.routes![0].visits!, { shipmentIndex: 2, startTime: "2026-10-05T15:50:00Z", shipmentLabel: "s3" }] }], skippedShipments: ok.skippedShipments };
    expect(() => interpretSegment(dup, ids, () => 120, () => undefined, start)).toThrow(ProviderInconsistencyError);
    const unknown = { routes: [{ visits: [{ shipmentLabel: "zz", startTime: "2026-10-05T15:10:00Z" }] }] };
    expect(() => interpretSegment(unknown, ["s1"], () => 120, () => undefined, start)).toThrow(ProviderInconsistencyError);
  });

  it("records lateness against soft deadlines", () => {
    const r = interpretSegment(ok, ids, () => 120, (id) => (id === "s1" ? new Date("2026-10-05T15:20:00Z") : undefined), start);
    expect(r.visits[1].lateBySeconds).toBe(600);
  });
});

describe("eligibility (mirrors the app's DeliveryLedger)", () => {
  const t = T0.getTime();

  it("derives package status from append-only outcomes in any order", () => {
    const outcomes = [
      outcomeDoc("o2", "p1", "s1", "delivered", t + 60_000),
      outcomeDoc("o1", "p1", "s1", "failed", t),
      outcomeDoc("o3", "p2", "s2", "skipped", t, true), // voided
    ];
    const statuses = packageStatuses([packageDoc(1), packageDoc(2)], outcomes);
    expect(statuses.get("p1")).toBe("delivered");
    expect(statuses.get("p2")).toBe("pending");
  });

  it("excludes completed, unverified and location-less stops with reasons", () => {
    const stops = [
      stopDoc(1),
      stopDoc(2, { addressStatus: "needsReview" }),
      stopDoc(3, { resolution: { provider: "google", match: "building", resolvedAt: stopDoc(3).resolution!.resolvedAt } }),
      stopDoc(4),
      stopDoc(5, { addressStatus: "demoSynthetic" }),
    ];
    const packages = [1, 2, 3, 4, 5].map((n) => packageDoc(n));
    const outcomes = [outcomeDoc("o1", "p4", "s4", "delivered", t)];
    const r = evaluateEligibility(stops, packages, outcomes, T0, false);
    expect(r.eligible.map((e) => e.stop.id)).toEqual(["s1"]);
    expect(r.excluded).toEqual(expect.arrayContaining([
      { stopId: "s2", reason: "addressNotVerified" },
      { stopId: "s3", reason: "noUsableLocation" },
      { stopId: "s4", reason: "completed" },
      { stopId: "s5", reason: "addressNotVerified" },
    ]));
    expect(r.completedStopIds).toEqual(["s4"]);
  });

  it("falls back to the place ID when cached coordinates have expired", () => {
    const expired = stopDoc(1);
    expired.resolution!.located!.expiresAt = { toMillis: () => T0.getTime() - 1 } as never;
    const r = evaluateEligibility([expired], [packageDoc(1)], [], T0, false);
    expect(r.eligible[0]).toEqual(expect.objectContaining({ placeId: "place-1", location: undefined }));
  });
});

describe("input validation", () => {
  const valid = {
    requestId: "req-1", routeId: "r1", inputRevision: 1, origin: { kind: "routeStart" },
    timeline: { departure: "2026-10-05T15:00:00Z", windows: {} },
  };

  it("accepts a valid request and applies defaults", () => {
    const v = parseInput(RequestOptimizationInput, valid);
    expect(v.computeBaseline).toBe(false);
    expect(v.considerTraffic).toBe(true);
  });

  it("rejects unknown fields, bad ids and coordinates outside Canada", () => {
    expect(() => parseInput(RequestOptimizationInput, { ...valid, extra: 1 })).toThrow();
    expect(() => parseInput(RequestOptimizationInput, { ...valid, routeId: "../x" })).toThrow();
    expect(() => parseInput(RequestOptimizationInput, { ...valid, origin: { kind: "currentLocation", latitude: 10, longitude: 10 } })).toThrow();
  });

  it("requires exactly one address query form", () => {
    expect(() => parseInput(ResolveAddressInput, {})).toThrow();
    expect(() => parseInput(ResolveAddressInput, { query: "123 Example St", placeId: "abc" })).toThrow();
    expect(parseInput(ResolveAddressInput, { address: { addressLines: ["123 Example St"], postalCode: "V8W 1A1" } })).toBeTruthy();
  });

  it("validates address suggestion requests", () => {
    const ok = { input: "123 Exam", sessionToken: "8F1C2D3E-AAAA-4BBB-8CCC-123456789ABC" };
    expect(parseInput(SuggestAddressesInput, ok)).toBeTruthy();
    expect(parseInput(SuggestAddressesInput, { ...ok, near: { latitude: 48.4, longitude: -123.4 }, languageCode: "fr" })).toBeTruthy();
    expect(() => parseInput(SuggestAddressesInput, { ...ok, input: "  1 " })).toThrow();
    expect(() => parseInput(SuggestAddressesInput, { ...ok, sessionToken: "bad token!" })).toThrow();
    expect(() => parseInput(SuggestAddressesInput, { ...ok, near: { latitude: 10, longitude: 10 } })).toThrow();
    expect(() => parseInput(SuggestAddressesInput, { ...ok, extra: 1 })).toThrow();
  });
});

describe("providers", () => {
  it("maps a Geocoding v4 result", () => {
    const c = mapV4Result({
      placeId: "abc", location: { latitude: 48.42, longitude: -123.36 }, granularity: "ROOFTOP", formattedAddress: "123 Example St, Victoria, BC V8W 1A1, Canada", types: ["street_address"],
      addressComponents: [
        { longText: "123", shortText: "123", types: ["street_number"] },
        { longText: "Example Street", shortText: "Example St", types: ["route"] },
        { longText: "Victoria", shortText: "Victoria", types: ["locality", "political"] },
        { longText: "British Columbia", shortText: "BC", types: ["administrative_area_level_1", "political"] },
        { longText: "V8W 1A1", shortText: "V8W 1A1", types: ["postal_code"] },
        { longText: "Canada", shortText: "CA", types: ["country", "political"] },
      ],
    });
    expect(c).toEqual(expect.objectContaining({ placeID: "abc", granularity: "rooftop", streetNumber: "123", route: "Example Street", provinceCode: "BC", postalCode: "V8W 1A1", countryCode: "CA", provider: "google" }));
  });

  it("builds a Canada-only, address-only Places Autocomplete request", () => {
    const body = buildAutocompleteBody({ input: "123 Exam", sessionToken: "tok-12345678", languageCode: "fr", near: { latitude: 48.4, longitude: -123.4 } });
    expect(body).toEqual({
      input: "123 Exam", sessionToken: "tok-12345678", includedRegionCodes: ["ca"], includedPrimaryTypes: ["street_address", "premise", "subpremise"], regionCode: "ca", languageCode: "fr",
      locationBias: { circle: { center: { latitude: 48.4, longitude: -123.4 }, radius: 50_000 } },
    });
    expect(buildAutocompleteBody({ input: "123 Exam", sessionToken: "tok-12345678" })).not.toHaveProperty("locationBias");
  });

  it("maps a Places Autocomplete prediction and skips incomplete ones", () => {
    expect(mapPlacePrediction({ placeId: "p1", text: { text: "123 Example St, Victoria, BC, Canada" }, structuredFormat: { mainText: { text: "123 Example St" }, secondaryText: { text: "Victoria, BC, Canada" } } }))
      .toEqual({ placeId: "p1", primaryText: "123 Example St", secondaryText: "Victoria, BC, Canada", provider: "google" });
    expect(mapPlacePrediction({ placeId: "p2", text: { text: "Full text only" } })).toEqual(expect.objectContaining({ primaryText: "Full text only" }));
    expect(mapPlacePrediction({ text: { text: "no id" } })).toBeNull();
    expect(mapPlacePrediction(undefined)).toBeNull();
  });

  it("emulator fake suggestion resolves back to the typed address", async () => {
    const [s] = await new FakeSuggester().suggest({ input: "123 Example St, Victoria BC V8W 1A1", sessionToken: "tok-12345678" });
    expect(s.provider).toBe("emulatorFake");
    const [c] = await new FakeGeocoder().geocode({ placeId: s.placeId });
    expect(c).toEqual(expect.objectContaining({ streetNumber: "123", postalCode: "V8W 1A1", granularity: "rooftop" }));
  });

  it("emulator fake geocoder returns only a postal area when the civic number is missing (E4)", async () => {
    const g = new FakeGeocoder();
    const full = await g.geocode({ address: { addressLines: ["123 EXAMPLE ST"], locality: "VICTORIA", province: "BC", postalCode: "V8W 1A1" } });
    expect(full[0]).toEqual(expect.objectContaining({ granularity: "rooftop", streetNumber: "123", provider: "emulatorFake" }));
    const noCivic = await g.geocode({ address: { addressLines: ["EXAMPLE ST"], locality: "VICTORIA", province: "BC", postalCode: "V8W 1A1" } });
    expect(noCivic[0]).toEqual(expect.objectContaining({ granularity: "approximate", types: ["postal_code"] }));
  });

  it("emulator fake optimizer answers in the Google response shape", async () => {
    const i = inputs();
    const { request, shipmentStopIds } = buildSegmentRequest(i, planSegments(i)[0], i.origin, i.departure, "req");
    const response = await new FakeTourOptimizer().optimizeTours(request);
    const r = interpretSegment(response, shipmentStopIds, () => 120, () => undefined, i.departure);
    expect(r.visits).toHaveLength(4);
  });

  it("retries only transient, unbilled failures — a bounded number of times", async () => {
    let calls = 0;
    await expect(withRetries(async () => { calls++; throw errors.providerUnavailable("503"); }, [1, 1])).rejects.toBeInstanceOf(AppError);
    expect(calls).toBe(3);
    calls = 0;
    await expect(withRetries(async () => { calls++; throw errors.providerUnavailable("timeout", true); }, [1, 1])).rejects.toBeInstanceOf(AppError);
    expect(calls).toBe(1);
    calls = 0;
    await expect(withRetries(async () => { calls++; throw errors.quotaExceeded("x", "y"); }, [1, 1])).rejects.toBeInstanceOf(AppError);
    expect(calls).toBe(1);
  });
});

describe("paid-feature access", () => {
  it("requires a verified email for email/password accounts only", () => {
    const blocked = () => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "password" }, email_verified: false });
    expect(blocked).toThrow(AppError);
    try { blocked(); } catch (e) { expect((e as AppError).reason).toBe("email-not-verified"); expect((e as AppError).code).toBe("failed-precondition"); }
    expect(() => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "password" } })).toThrow(AppError);
    expect(() => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "password" }, email_verified: true })).not.toThrow();
    expect(() => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "google.com" }, email_verified: true })).not.toThrow();
    expect(() => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "apple.com" } })).not.toThrow();
    expect(() => assertMayUsePaidFeatures({ firebase: { sign_in_provider: "anonymous" } })).not.toThrow();
  });
});
