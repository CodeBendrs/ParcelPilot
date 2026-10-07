/**
 * Integration tests for the callable handlers against the Firestore + Auth emulators:
 *   npm --prefix .. run test:functions:integration   (from firebase/functions)
 * Uses the emulator-only fake optimizer/geocoder (no Google calls, no billing).
 */
import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, Timestamp, type Firestore } from "firebase-admin/firestore";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteAccount } from "../../src/account";
import { AppError, errors } from "../../src/errors";
import { requestOptimization, type OptimizationDeps } from "../../src/optimization/run";
import { rfc3339, wallClockToInstant } from "../../src/optimization/time";
import { FakeGeocoder, FakeSuggester, FakeTourOptimizer, type FakeOptimizerHooks } from "../../src/providers/fake";
import { GoogleGeocoder } from "../../src/providers/google";
import type { Limits } from "../../src/quota";
import { resolveAddress } from "../../src/resolveAddress";
import { purgeExpiredProviderContent } from "../../src/retention";
import { suggestAddresses } from "../../src/suggestAddresses";
import type { RouteDoc, StopDoc } from "../../src/types";
import { packageDoc, routeDoc, stopDoc } from "../helpers";

let db: Firestore;
const NOW = new Date("2026-10-05T14:00:00Z"); // 07:00 in Vancouver, before the 08:00 departure
const limits: Limits = { maxEligibleStops: 200, dailyGeocodesPerUser: 100, dailyOptimizationsPerUser: 50, dailyShipmentsPerUser: 5000, monthlyGeocodeBudget: 1000, monthlyShipmentBudget: 20000, dailySuggestionsPerUser: 100, monthlySuggestionBudget: 1000 };

beforeAll(() => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) throw new Error("Run via firebase emulators:exec (FIRESTORE_EMULATOR_HOST not set)");
  if (!getApps().length) initializeApp({ projectId: "demo-parcelpilot" });
  db = getFirestore();
});

beforeEach(async () => {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/demo-parcelpilot/databases/(default)/documents`, { method: "DELETE" });
});

function deps(optimizer = new FakeTourOptimizer(), extra: Partial<OptimizationDeps> = {}): OptimizationDeps {
  return { db, optimizer, limits, now: () => NOW, allowSynthetic: false, retryDelaysMs: [1, 1], ...extra };
}

async function seed(uid: string, stops: StopDoc[], route: Partial<RouteDoc> = {}) {
  const r = routeDoc(route);
  for (const k of Object.keys(r) as Array<keyof RouteDoc>) if (r[k] === undefined) delete r[k];
  const batch = db.batch();
  batch.set(db.doc(`users/${uid}/routes/${r.id}`), r);
  for (const s of stops) {
    batch.set(db.doc(`users/${uid}/routes/${r.id}/stops/${s.id}`), s);
    batch.set(db.doc(`users/${uid}/routes/${r.id}/packages/p-${s.id}`), { ...packageDoc(0, s.id), id: `p-${s.id}` });
  }
  await batch.commit();
  return r;
}

function timeline(route: RouteDoc, stops: StopDoc[]) {
  const at = (m: number) => rfc3339(wallClockToInstant(route.serviceDate, m, route.timeZoneID).date);
  const windows: Record<string, { start?: string; end: string }> = {};
  for (const s of stops) if (s.timeWindow) windows[s.id] = { ...(s.timeWindow.startMinute !== undefined ? { start: at(s.timeWindow.startMinute) } : {}), end: at(s.timeWindow.endMinute) };
  return { departure: at(route.departureMinute), windows, ...(route.latestArrivalMinute !== undefined ? { latestArrival: at(route.latestArrivalMinute) } : {}), ...(route.breakRule ? { breakWindow: { earliest: at(route.breakRule.earliestStartMinute), latest: at(route.breakRule.latestStartMinute) } } : {}) };
}

function request(route: RouteDoc, stops: StopDoc[], extra: Record<string, unknown> = {}) {
  return { requestId: `req-${Math.random().toString(36).slice(2, 10)}`, routeId: route.id, inputRevision: route.inputRevision, origin: { kind: "routeStart" }, timeline: timeline(route, stops), ...extra };
}

const stops = (n: number) => Array.from({ length: n }, (_, k) => stopDoc(k + 1));

async function expectAppError(p: Promise<unknown>, code: string, reason?: string) {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(AppError);
    expect((e as AppError).code).toBe(code);
    if (reason) expect((e as AppError).reason).toBe(reason);
    return e as AppError;
  }
  throw new Error("expected an error");
}

describe("requestOptimization", () => {
  it("loads standalone work: pickup-only visits are planned and optional-only visits are omitted", async () => {
    const s = stops(3);
    const route = await seed("alice", s);
    const ref = db.doc(`users/alice/routes/${route.id}`);
    const batch = db.batch();
    batch.delete(ref.collection("packages").doc("p-s1"));
    batch.delete(ref.collection("packages").doc("p-s2"));
    for (const [id, stopID, required] of [["pickup", "s1", true], ["optional", "s2", false]] as const) {
      batch.set(ref.collection("tasks").doc(id), { id, schemaVersion: 1, stopID, kind: "pickup", required, title: "Collect return", instructions: "", orderRank: 0, createdAt: Timestamp.fromDate(NOW), updatedAt: Timestamp.fromDate(NOW) });
    }
    await batch.commit();
    let req = request(route, s);
    expect((await requestOptimization(deps(), "alice", req)).status).toBe("succeeded");
    let proposal = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!.proposal;
    expect(proposal.visits.map((visit: { stopId: string }) => visit.stopId).sort()).toEqual(["s1", "s3"]);
    expect(proposal.excluded).toContainEqual({ stopId: "s2", reason: "noPendingPackages" });
    const completion = db.batch();
    completion.set(ref.collection("outcomes").doc("complete"), { id: "complete", schemaVersion: 2, taskID: "pickup", stopID: "s1", kind: "completed", recordedAt: Timestamp.fromDate(NOW), photoIDs: [] });
    completion.update(ref, { inputRevision: 2 });
    await completion.commit();
    req = request({ ...route, inputRevision: 2 }, s);
    await requestOptimization(deps(), "alice", req);
    proposal = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!.proposal;
    expect(proposal.visits.map((visit: { stopId: string }) => visit.stopId)).toEqual(["s3"]);
    expect(proposal.completedStopIdsAtRequest).toEqual(["s1"]);
  });

  it.each([{ kind: "future-work", stopID: "s1" }, { kind: "pickup", stopID: "removed-stop" }])("refuses a proposal for unsafe required work before any provider call: %j", async (extra) => {
    const s = stops(2);
    const route = await seed("alice", s);
    await db.doc(`users/alice/routes/${route.id}/tasks/unsafe`).set({ id: "unsafe", schemaVersion: 1, required: true, title: "Unknown required work", instructions: "", orderRank: 0, createdAt: Timestamp.fromDate(NOW), updatedAt: Timestamp.fromDate(NOW), ...extra });
    const optimizer = new FakeTourOptimizer();
    await expectAppError(requestOptimization(deps(optimizer), "alice", request(route, s)), "failed-precondition", "unsupported-work");
    expect(optimizer.requests).toHaveLength(0);
    expect((await db.doc("users/alice/usage/2026-10-05").get()).data()?.optimizations ?? 0).toBe(0);
  });

  it("a task outcome during optimization makes the proposal stale and retains the outcome", async () => {
    const s = stops(2);
    const route = await seed("alice", s);
    const ref = db.doc(`users/alice/routes/${route.id}`);
    await ref.collection("tasks").doc("pickup").set({ id: "pickup", schemaVersion: 1, stopID: "s1", kind: "pickup", required: true, title: "Collect return", instructions: "", orderRank: 0, createdAt: Timestamp.fromDate(NOW), updatedAt: Timestamp.fromDate(NOW) });
    const optimizer = new FakeTourOptimizer({ beforeRespond: async () => {
      const batch = db.batch();
      batch.set(ref.collection("outcomes").doc("complete"), { id: "complete", schemaVersion: 2, taskID: "pickup", stopID: "s1", kind: "completed", recordedAt: Timestamp.fromDate(NOW), photoIDs: [] });
      batch.update(ref, { inputRevision: 2 });
      await batch.commit();
    } });
    const req = request(route, s);
    expect((await requestOptimization(deps(optimizer), "alice", req)).status).toBe("stale");
    expect((await ref.collection("outcomes").doc("complete").get()).data()?.kind).toBe("completed");
    expect((await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()?.proposal).toBeUndefined();
  });

  it("rejects malformed task reads instead of treating a missing required flag as optional", async () => {
    const s = stops(2);
    const route = await seed("alice", s);
    await db.doc(`users/alice/routes/${route.id}/tasks/bad`).set({ id: "bad", schemaVersion: 1, stopID: "s1", kind: "pickup", title: "Collect return", instructions: "", orderRank: 0, createdAt: Timestamp.fromDate(NOW), updatedAt: Timestamp.fromDate(NOW) });
    const optimizer = new FakeTourOptimizer();
    await expectAppError(requestOptimization(deps(optimizer), "alice", request(route, s)), "failed-precondition", "unsupported-work");
    expect(optimizer.requests).toHaveLength(0);
  });

  it("includes warehouse arrival in a feasible overnight route and passes the limit to every pinned segment", async () => {
    const s = stops(4);
    s[0].pin = "first";
    s[3].pin = "last";
    const route = await seed("alice", s, { departureMinute: 1380, latestArrivalMinute: 1500 });
    const optimizer = new FakeTourOptimizer();
    const req = request(route, s);
    expect((await requestOptimization(deps(optimizer), "alice", req)).status).toBe("succeeded");
    const job = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!;
    const limit = Date.parse(timeline(route, s).latestArrival!);
    expect(job.proposal.metrics.routeEnd.toMillis()).toBeLessThanOrEqual(limit);
    expect(optimizer.requests).toHaveLength(3);
    for (const sent of optimizer.requests) expect(sent.model.vehicles[0].endTimeWindows?.[0].endTime).toBe(timeline(route, s).latestArrival);
  });

  it("reports unscheduled deliveries with a tight arrival limit and never silently drops them", async () => {
    const s = stops(3);
    const route = await seed("alice", s, { latestArrivalMinute: 485, defaultServiceSeconds: 600 });
    const req = request(route, s);
    expect((await requestOptimization(deps(), "alice", req)).status).toBe("infeasible");
    const job = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!;
    expect(job.proposal.unassigned).toHaveLength(3);
    expect(job.proposal.visits).toHaveLength(0);
    expect(job.proposal.warnings.join(" ")).toContain("latest arrival");
    expect((await db.collection(`users/alice/routes/${route.id}/stops`).get()).size).toBe(3);
  });

  it("rejects a missing or inconsistent deadline, an absent warehouse, and replanning after the deadline before provider calls", async () => {
    const s = stops(1);
    const route = await seed("alice", s, { latestArrivalMinute: 1020 });
    const optimizer = new FakeTourOptimizer();
    const missing = timeline(route, s);
    delete missing.latestArrival;
    await expectAppError(requestOptimization(deps(optimizer), "alice", request(route, s, { timeline: missing })), "invalid-argument");
    await expectAppError(requestOptimization(deps(optimizer), "alice", request(route, s, { timeline: { ...timeline(route, s), latestArrival: "2026-10-08T00:00:00Z" } })), "invalid-argument");
    const lateDeps = deps(optimizer, { now: () => wallClockToInstant(route.serviceDate, 1021, route.timeZoneID).date });
    await expectAppError(requestOptimization(lateDeps, "alice", request(route, s, { departNow: true })), "failed-precondition", "arrival-deadline-passed");
    const noWarehouse = await seed("alice", s, { latestArrivalMinute: 1020, start: undefined });
    await expectAppError(requestOptimization(deps(optimizer), "alice", request(noWarehouse, s, { origin: { kind: "currentLocation", latitude: 48.4, longitude: -123.3 } })), "failed-precondition", "missing-end");
    expect(optimizer.requests).toHaveLength(0);
  });

  it("produces a verified proposal covering every eligible stop exactly once", async () => {
    const s = stops(8);
    const route = await seed("alice", s);
    const req = request(route, s);
    const result = await requestOptimization(deps(), "alice", req);
    expect(result.status).toBe("succeeded");
    const job = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!;
    expect(job.status).toBe("succeeded");
    expect(job.provider).toBe("emulatorFake");
    expect(job.proposal.visits.map((v: { stopId: string }) => v.stopId).sort()).toEqual(s.map((x) => x.id).sort());
    expect(job.proposal.trafficConsidered).toBe(false); // the fake provider never claims traffic
    expect(job.expiresAt.toMillis()).toBe(NOW.getTime() + 24 * 3600_000);
    expect((await db.doc(`users/alice/optimizationLocks/${route.id}`).get()).exists).toBe(false);
  });

  it("E10: a second user cannot optimize (or see) another user's route", async () => {
    const s = stops(3);
    const route = await seed("alice", s);
    await expectAppError(requestOptimization(deps(), "bob", request(route, s)), "not-found");
    expect((await db.collection("users/alice/optimizationRequests").get()).size).toBe(0);
  });

  it("is idempotent per request ID (repeated taps do not repeat paid calls)", async () => {
    const s = stops(4);
    const route = await seed("alice", s);
    const optimizer = new FakeTourOptimizer();
    const req = request(route, s);
    const first = await requestOptimization(deps(optimizer), "alice", req);
    const second = await requestOptimization(deps(optimizer), "alice", req);
    expect(first.reused).toBe(false);
    expect(second).toEqual(expect.objectContaining({ reused: true, status: "succeeded" }));
    expect(optimizer.requests).toHaveLength(1);
  });

  it("returns the running job instead of starting a second one for the same route", async () => {
    const s = stops(4);
    const route = await seed("alice", s);
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const optimizer = new FakeTourOptimizer({ beforeRespond: () => gate });
    const firstReq = request(route, s);
    const firstPromise = requestOptimization(deps(optimizer), "alice", firstReq);
    await new Promise((r) => setTimeout(r, 300));
    const second = await requestOptimization(deps(optimizer), "alice", request(route, s));
    expect(second).toEqual({ requestId: firstReq.requestId, status: "running", reused: true });
    release();
    expect((await firstPromise).status).toBe("succeeded");
    expect(optimizer.requests).toHaveLength(1);
  });

  it("E8: an edit during optimization makes the result stale and keeps the edit", async () => {
    const s = stops(5);
    const route = await seed("alice", s);
    const hooks: FakeOptimizerHooks = {
      beforeRespond: async () => {
        await db.doc(`users/alice/routes/${route.id}`).update({ inputRevision: 2, name: "Edited mid-flight" });
      },
    };
    const req = request(route, s);
    const result = await requestOptimization(deps(new FakeTourOptimizer(hooks)), "alice", req);
    expect(result.status).toBe("stale");
    const job = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!;
    expect(job.proposal).toBeUndefined();
    expect(job.error.reason).toBe("route-changed");
    const after = (await db.doc(`users/alice/routes/${route.id}`).get()).data()!;
    expect(after.name).toBe("Edited mid-flight");
    expect(after.inputRevision).toBe(2);
  });

  it("explains revision mismatches (device behind / changes not yet synced)", async () => {
    const s = stops(2);
    const route = await seed("alice", s, { inputRevision: 3 });
    await expectAppError(requestOptimization(deps(), "alice", { ...request(route, s), inputRevision: 2 }), "failed-precondition", "revision-behind");
    await expectAppError(requestOptimization(deps(), "alice", { ...request(route, s), inputRevision: 4 }), "failed-precondition", "revision-ahead");
  });

  it("E7: incompatible hard windows are reported as unassigned; every stop and package retained", async () => {
    const far1 = stopDoc(1, { timeWindow: { kind: "hard", startMinute: 480, endMinute: 495 } });
    far1.resolution!.located!.point = { latitude: 48.30, longitude: -123.60 };
    const far2 = stopDoc(2, { timeWindow: { kind: "hard", startMinute: 480, endMinute: 495 } });
    far2.resolution!.located!.point = { latitude: 48.70, longitude: -123.10 };
    const s = [far1, far2, stopDoc(3), stopDoc(4)];
    const route = await seed("alice", s);
    const req = request(route, s);
    const result = await requestOptimization(deps(), "alice", req);
    expect(result.status).toBe("infeasible");
    const p = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!.proposal;
    expect(p.unassigned.length).toBeGreaterThan(0);
    for (const u of p.unassigned) expect(u.suggestions.length).toBeGreaterThan(0);
    expect(p.visits.length + p.unassigned.length).toBe(4);
    expect((await db.collection(`users/alice/routes/${route.id}/packages`).get()).size).toBe(4);
    expect((await db.collection(`users/alice/routes/${route.id}/stops`).get()).size).toBe(4);
  });

  it("enforces pins and the fixed next stop with consistent times", async () => {
    const s = stops(9).map((x) => (x.id === "s7" ? { ...x, pin: "first" as const } : x.id === "s2" ? { ...x, pin: "last" as const } : x));
    const route = await seed("alice", s);
    const req = request(route, s);
    await requestOptimization(deps(), "alice", req);
    const p = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!.proposal;
    expect(p.visits[0].stopId).toBe("s7");
    expect(p.visits[p.visits.length - 1].stopId).toBe("s2");
    for (let i = 1; i < p.visits.length; i++) expect(p.visits[i].arrival.toMillis()).toBeGreaterThanOrEqual(p.visits[i - 1].departure.toMillis());
    const fixed = request(route, s, { fixedNextStopId: "s5" });
    await requestOptimization(deps(), "alice", fixed);
    const q = (await db.doc(`users/alice/optimizationRequests/${fixed.requestId}`).get()).data()!.proposal;
    expect(q.visits[0].stopId).toBe("s5");
  });

  it("optimizes only remaining work and lists completed stops", async () => {
    const s = stops(4);
    const route = await seed("alice", s);
    await db.doc(`users/alice/routes/${route.id}/outcomes/o1`).set({ id: "o1", schemaVersion: 1, packageID: "p-s1", stopID: "s1", kind: "delivered", recordedAt: Timestamp.fromDate(NOW), photoIDs: [] });
    const req = request(route, s, { origin: { kind: "currentLocation", latitude: 48.43, longitude: -123.37 }, departNow: true });
    await requestOptimization(deps(), "alice", req);
    const p = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!.proposal;
    expect(p.visits.map((v: { stopId: string }) => v.stopId)).not.toContain("s1");
    expect(p.completedStopIdsAtRequest).toEqual(["s1"]);
    expect(p.excluded).toEqual(expect.arrayContaining([{ stopId: "s1", reason: "completed" }]));
  });

  it("rejects a timeline that does not match the route's time zone", async () => {
    const s = stops(2);
    const route = await seed("alice", s);
    const req = request(route, s);
    req.timeline.departure = "2026-10-05T23:00:00Z";
    await expectAppError(requestOptimization(deps(), "alice", req), "invalid-argument");
  });

  it("E10: quota exhaustion returns a useful error and leaks no reservation", async () => {
    const s = stops(3);
    const route = await seed("alice", s);
    const tight = { ...limits, dailyOptimizationsPerUser: 1 };
    await requestOptimization(deps(undefined, { limits: tight }), "alice", request(route, s));
    const e = await expectAppError(requestOptimization(deps(undefined, { limits: tight }), "alice", request(route, s)), "resource-exhausted", "quota-exceeded");
    expect(e.message).toMatch(/limit reached/);
    const usage = (await db.doc("users/alice/usage/2026-10-05").get()).data()!;
    expect(usage.optimizations).toBe(1);
    const monthly = { ...limits, monthlyShipmentBudget: 2 };
    await expectAppError(requestOptimization(deps(undefined, { limits: monthly }), "bob", request(await seed("bob", s), s)), "resource-exhausted");
  });

  it("missing origin and provider outages fail cleanly, release quota and keep the plan untouched", async () => {
    const s = stops(3);
    const route = await seed("alice", s, { start: undefined, returnToStart: false });
    await expectAppError(requestOptimization(deps(), "alice", request(route, s)), "failed-precondition", "missing-origin");
    expect((await db.doc("users/alice/usage/2026-10-05").get()).data()?.optimizations ?? 0).toBe(0);

    const route2 = await seed("carol", s);
    const failing = new FakeTourOptimizer({ failWith: errors.providerUnavailable("HTTP 503") });
    const req = request(route2, s);
    await expectAppError(requestOptimization(deps(failing), "carol", req), "unavailable");
    expect(failing.requests).toHaveLength(3); // initial + 2 bounded retries
    const job = (await db.doc(`users/carol/optimizationRequests/${req.requestId}`).get()).data()!;
    expect(job.status).toBe("failed");
    expect(job.error.message).toMatch(/unchanged/);
    const usage = (await db.doc("users/carol/usage/2026-10-05").get()).data()!;
    expect(usage.optimizations).toBe(0);
    expect((await db.collection(`users/carol/routes/${route2.id}/stops`).get()).size).toBe(3);
  });

  it("E10: missing Google configuration produces an actionable error, not fabricated results", async () => {
    const saved = { ...process.env };
    process.env.GOOGLE_APPLICATION_CREDENTIALS = "/nonexistent/credentials.json";
    try {
      const e = await expectAppError(new GoogleGeocoder().geocode({ query: "123 Example St, Victoria BC" }), "failed-precondition", "not-configured");
      expect(e.suggestions.join(" ")).toMatch(/COST_AND_SETUP/);
    } finally {
      process.env = saved;
    }
  });

  it.each([10, 50, 200])("timing (emulator + FAKE provider, not Google): %i stops", async (n) => {
    const s = stops(n);
    const route = await seed(`bench${n}`, s);
    const t0 = performance.now();
    const result = await requestOptimization(deps(), `bench${n}`, request(route, s));
    const ms = Math.round(performance.now() - t0);
    console.log(`[benchmark][emulator-fake-provider][handler end-to-end] stops=${n} ms=${ms}`);
    expect(result.status).toBe("succeeded");
  });

  it("refuses more eligible stops than the product limit", async () => {
    const s = stops(12);
    const route = await seed("alice", s);
    await expectAppError(requestOptimization(deps(undefined, { limits: { ...limits, maxEligibleStops: 10 } }), "alice", request(route, s)), "failed-precondition", "too-many-stops");
  });
});

// E11 timings. MOCKED provider: this measures the function's own work (validation, Firestore reads,
// quota transaction, lock, request building, exactly-once verification, job write) against the local
// emulator with the emulator-only fake optimizer. It does NOT include Google's solver time or network
// latency; live timings require the Route Optimization API (see IMPLEMENTATION_STATUS.md).
describe("E11 timings with the mocked provider", () => {
  for (const n of [10, 50, 200]) {
    it(`${n} stops: every stop scheduled exactly once; handler time recorded`, async () => {
      const s = stops(n);
      const route = await seed("alice", s);
      const req = request(route, s);
      const started = performance.now();
      const result = await requestOptimization(deps(), "alice", req);
      const ms = performance.now() - started;
      expect(result.status).toBe("succeeded");
      const job = (await db.doc(`users/alice/optimizationRequests/${req.requestId}`).get()).data()!;
      expect(new Set(job.proposal.visits.map((v: { stopId: string }) => v.stopId)).size).toBe(n);
      console.log(`E11 mocked-provider stops=${n} requestOptimization ms=${ms.toFixed(0)} (emulator Firestore, fake optimizer, no Google/network time)`);
    });
  }
});

describe("resolveAddress", () => {
  it("returns candidates with a 30-day coordinate expiry and counts usage", async () => {
    const r = await resolveAddress({ db, geocoder: new FakeGeocoder(), limits, now: () => NOW }, "alice", { address: { addressLines: ["123 EXAMPLE ST"], locality: "VICTORIA", province: "BC", postalCode: "V8W 1A1" } });
    expect(r.provider).toBe("emulatorFake");
    expect(r.candidates[0].streetNumber).toBe("123");
    expect(Date.parse(r.coordinatesExpireAt) - NOW.getTime()).toBe(30 * 86_400_000);
    expect((await db.doc("users/alice/usage/2026-10-05").get()).data()!.geocodes).toBe(1);
  });

  it("enforces the per-user daily limit", async () => {
    const d = { db, geocoder: new FakeGeocoder(), limits: { ...limits, dailyGeocodesPerUser: 1 }, now: () => NOW };
    await resolveAddress(d, "alice", { query: "123 Example St, Victoria BC V8W 1A1" });
    await expectAppError(resolveAddress(d, "alice", { query: "124 Example St, Victoria BC V8W 1A1" }), "resource-exhausted");
  });

  it("validates input", async () => {
    await expectAppError(resolveAddress({ db, geocoder: new FakeGeocoder(), limits, now: () => NOW }, "alice", { query: "x" }), "invalid-argument");
  });
});

describe("suggestAddresses", () => {
  const input = { input: "123 Example St", sessionToken: "session-12345678" };

  it("returns suggestions without coordinates and counts usage", async () => {
    const r = await suggestAddresses({ db, suggester: new FakeSuggester(), limits, now: () => NOW }, "alice", input);
    expect(r.provider).toBe("emulatorFake");
    expect(r.suggestions[0]).not.toHaveProperty("location");
    expect((await db.doc("users/alice/usage/2026-10-05").get()).data()!.suggestions).toBe(1);
    expect((await db.doc("system/usage/months/2026-10").get()).data()!.suggestions).toBe(1);
  });

  it("enforces the per-user daily and project monthly limits", async () => {
    const daily = { db, suggester: new FakeSuggester(), limits: { ...limits, dailySuggestionsPerUser: 1 }, now: () => NOW };
    await suggestAddresses(daily, "alice", input);
    await expectAppError(suggestAddresses(daily, "alice", input), "resource-exhausted");
    const monthly = { db, suggester: new FakeSuggester(), limits: { ...limits, monthlySuggestionBudget: 2 }, now: () => NOW };
    await suggestAddresses(monthly, "bob", input);
    await expectAppError(suggestAddresses(monthly, "carol", input), "resource-exhausted");
  });

  it("releases the reservation when the provider certainly did not bill", async () => {
    const failing = { provider: "google" as const, suggest: async () => { throw errors.notConfigured("Places API access", "Enable it."); } };
    await expectAppError(suggestAddresses({ db, suggester: failing, limits, now: () => NOW }, "alice", input), "failed-precondition");
    expect((await db.doc("users/alice/usage/2026-10-05").get()).data()!.suggestions).toBe(0);
  });

  it("validates input before using quota", async () => {
    await expectAppError(suggestAddresses({ db, suggester: new FakeSuggester(), limits, now: () => NOW }, "alice", { input: "x", sessionToken: "session-12345678" }), "invalid-argument");
    expect((await db.doc("users/alice/usage/2026-10-05").get()).exists).toBe(false);
  });
});

describe("deleteAccount", () => {
  it("deletes all of the user's data, files and auth record; leaves other users alone", async () => {
    const auth = getAuth();
    await auth.createUser({ uid: "dana" }).catch(() => undefined);
    await seed("dana", stops(3));
    await seed("erin", stops(1));
    const prefixes: string[] = [];
    const nowSec = Math.floor(NOW.getTime() / 1000);
    await deleteAccount({ db, auth, deleteStoragePrefix: async (p) => { prefixes.push(p); }, now: () => NOW }, "dana", nowSec - 60);
    expect((await db.collection("users/dana/routes").get()).size).toBe(0);
    expect((await db.collection("users/dana/routes/r1/stops").get()).size).toBe(0);
    expect((await db.collection("users/erin/routes").get()).size).toBe(1);
    expect(prefixes).toEqual(["users/dana/"]);
    await expect(auth.getUser("dana")).rejects.toBeTruthy();
    // Idempotent re-run.
    await deleteAccount({ db, auth, deleteStoragePrefix: async () => undefined, now: () => NOW }, "dana", nowSec - 60);
  });

  it("requires a recent sign-in", async () => {
    const nowSec = Math.floor(NOW.getTime() / 1000);
    await expectAppError(deleteAccount({ db, auth: getAuth(), deleteStoragePrefix: async () => undefined, now: () => NOW }, "dana", nowSec - 3600), "failed-precondition", "recent-sign-in-required");
  });
});

describe("retention purge", () => {
  it("removes expired provider coordinates and jobs, keeps place IDs and driver data", async () => {
    const expired = stopDoc(1);
    expired.resolution!.located!.expiresAt = Timestamp.fromMillis(NOW.getTime() - 1000);
    const pinned = stopDoc(2, { resolution: { provider: undefined, match: "driverPin", resolvedAt: Timestamp.fromDate(NOW), located: { point: { latitude: 48.4, longitude: -123.3 }, source: "driverPin" } } });
    delete (pinned.resolution as { provider?: string }).provider;
    await seed("alice", [expired, pinned, stopDoc(3)]);
    await db.doc("users/alice/optimizationRequests/old").set({ status: "succeeded", expiresAt: Timestamp.fromMillis(NOW.getTime() - 1000) });
    await db.doc("users/alice/optimizationRequests/new").set({ status: "succeeded", expiresAt: Timestamp.fromMillis(NOW.getTime() + 1000) });
    const counts = await purgeExpiredProviderContent(db, NOW);
    expect(counts.jobs).toBe(1);
    expect(counts.stopCoordinates).toBe(1);
    const s1 = (await db.doc("users/alice/routes/r1/stops/s1").get()).data()!;
    expect(s1.resolution.located).toBeUndefined();
    expect(s1.resolution.placeID).toBe("place-1");
    expect((await db.doc("users/alice/routes/r1/stops/s2").get()).data()!.resolution.located).toBeDefined();
    expect((await db.doc("users/alice/optimizationRequests/new").get()).exists).toBe(true);
  });
});
