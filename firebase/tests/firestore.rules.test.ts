/**
 * Firestore security rules tests (run against the emulator: `npm run test:rules`).
 * Documents are shaped exactly like the iOS app writes them (Swift Codable via the Firestore encoder).
 */
import { assertFails, assertSucceeds, initializeTestEnvironment, type RulesTestEnvironment } from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, serverTimestamp, setDoc, Timestamp, updateDoc, writeBatch } from "firebase/firestore";
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

let env: RulesTestEnvironment;
const now = () => Timestamp.now();
const inDays = (d: number) => Timestamp.fromMillis(Date.now() + d * 86_400_000);

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-parcelpilot",
    firestore: { rules: readFileSync("firestore.rules", "utf8") },
  });
});
afterAll(async () => env.cleanup());
beforeEach(async () => env.clearFirestore());

const alice = () => env.authenticatedContext("alice").firestore();
const bob = () => env.authenticatedContext("bob").firestore();
const anon = () => env.unauthenticatedContext().firestore();

function route(id = "r1", extra: Record<string, unknown> = {}) {
  return {
    id, schemaVersion: 1, name: "Monday", status: "planning", createdAt: now(), updatedAt: now(),
    serviceDate: "2026-10-05", timeZoneID: "America/Vancouver", departureMinute: 480,
    start: { label: "Depot", located: { point: { latitude: 48.42, longitude: -123.36 }, source: "driverPin" } },
    returnToStart: true, defaultServiceSeconds: 120, objective: "balanced", considerTraffic: true, inputRevision: 1,
    ...extra,
  };
}

const address = { recipientName: "ALEX TEST", unit: "204", unitDesignator: "Unit", civicNumber: "123", streetName: "EXAMPLE ST", municipality: "VICTORIA", province: "BC", postalCode: "V8W 1A1", country: "CA", additionalLines: [] };

function stop(id = "s1", extra: Record<string, unknown> = {}) {
  return {
    id, schemaVersion: 1, createdAt: now(), updatedAt: now(), address, destinationKey: "C|123|EXAMPLE ST|204|V8W1A1",
    addressStatus: "verified",
    resolution: { provider: "google", placeID: "abc", match: "building", resolvedAt: now(), located: { point: { latitude: 48.42, longitude: -123.36 }, source: "providerGeocode", expiresAt: inDays(30) } },
    reviewReasons: [], sequence: 1, pin: "none", notes: "",
    ...extra,
  };
}

function pkg(id = "p1", extra: Record<string, unknown> = {}) {
  return { id, schemaVersion: 1, stopID: "s1", createdAt: now(), updatedAt: now(), trackingID: "1Z999AA10123456784", trackingKey: "1Z999AA10123456784", notes: "", source: "scan", ...extra };
}

function outcome(id = "o1", extra: Record<string, unknown> = {}) {
  return { id, schemaVersion: 1, packageID: "p1", stopID: "s1", kind: "delivered", recordedAt: now(), photoIDs: [], ...extra };
}

function task(id = "t1", extra: Record<string, unknown> = {}) {
  return { id, schemaVersion: 1, stopID: "s1", kind: "pickup", required: true, title: "Collect return", instructions: "", orderRank: 0, createdAt: now(), updatedAt: now(), ...extra };
}

function taskEvent(id = "o1", extra: Record<string, unknown> = {}) {
  return { id, schemaVersion: 2, taskID: "t1", stopID: "s1", kind: "completed", recordedAt: now(), photoIDs: [], ...extra };
}

async function seedWork(extra: Record<string, unknown> = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, routePath()), route());
    await setDoc(doc(db, `${routePath()}/stops/s1`), stop());
    await setDoc(doc(db, `${routePath()}/packages/p1`), pkg());
    await setDoc(doc(db, `${routePath()}/tasks/t1`), task("t1", extra));
  });
}

function revisionBatch(db = alice(), revision = 2) {
  const batch = writeBatch(db);
  batch.update(doc(db, routePath()), { inputRevision: revision, updatedAt: now() });
  return batch;
}

const routePath = (uid = "alice", id = "r1") => `users/${uid}/routes/${id}`;

const executionPath = (uid = "alice") => `users/${uid}/execution/current`;
function execution(extra: Record<string, unknown> = {}) {
  const at = now();
  return { id: "session1", routeID: "r1", schemaVersion: 1, state: "active", startedAt: at, changedAt: at, transitionCount: 0, ...extra };
}

describe("explicit account execution session", () => {
  async function started() {
    const db = alice();
    await assertSucceeds(setDoc(doc(db, routePath()), route()));
    const value = execution();
    await assertSucceeds(setDoc(doc(db, executionPath()), value));
    return { db, value, ref: doc(db, executionPath()) };
  }

  it("starts, pauses and resumes without changing route revision or work", async () => {
    const { db, ref } = await started();
    await assertSucceeds(updateDoc(ref, { state: "paused", changedAt: now(), transitionCount: 1 }));
    await assertSucceeds(updateDoc(ref, { state: "active", changedAt: now(), transitionCount: 2 }));
    expect((await getDoc(doc(db, routePath()))).data()!.inputRevision).toBe(1);
    expect((await getDoc(ref)).data()!.transitionCount).toBe(2);
  });

  it("owner binding and singleton path forbid another account and second current record", async () => {
    await started();
    await assertFails(getDoc(doc(bob(), executionPath())));
    await assertFails(getDoc(doc(anon(), executionPath())));
    await assertFails(setDoc(doc(bob(), executionPath()), execution()));
    await assertFails(setDoc(doc(alice(), "users/alice/execution/another"), execution()));
    await assertFails(deleteDoc(doc(alice(), executionPath())));
  });

  it("another route cannot replace active or paused execution", async () => {
    const { db, ref } = await started();
    await assertSucceeds(setDoc(doc(db, routePath("alice", "r2")), route("r2")));
    await assertFails(setDoc(ref, execution({ id: "session2", routeID: "r2" })));
    await assertSucceeds(updateDoc(ref, { state: "paused", changedAt: now(), transitionCount: 1 }));
    await assertFails(setDoc(ref, execution({ id: "session2", routeID: "r2" })));
  });

  it("rejects invalid starts, identity changes, repeated transitions and timestamp regressions", async () => {
    const db = alice();
    await setDoc(doc(db, routePath()), route());
    for (const extra of [
      { state: "paused" }, { state: "finished" }, { transitionCount: 1 }, { schemaVersion: 2 },
      { routeID: "missing" }, { unexpected: true }, { changedAt: Timestamp.fromMillis(0) }, { id: "bad/id" },
    ]) await assertFails(setDoc(doc(db, executionPath()), execution(extra)));
    const value = execution();
    const ref = doc(db, executionPath());
    await assertSucceeds(setDoc(ref, value));
    for (const extra of [
      { state: "active", transitionCount: 1 }, { state: "paused", transitionCount: 0 },
      { state: "paused", transitionCount: 2 }, { state: "paused", transitionCount: 1, id: "changed" },
      { state: "paused", transitionCount: 1, startedAt: Timestamp.fromMillis(0) },
      { state: "paused", transitionCount: 1, changedAt: Timestamp.fromMillis(0) },
    ]) await assertFails(updateDoc(ref, { changedAt: now(), ...extra }));
  });

  it("Finish and closed-route summary must be one atomic operation", async () => {
    const { db, ref } = await started();
    await assertFails(updateDoc(ref, { state: "finished", changedAt: now(), transitionCount: 1 }));
    await assertFails(updateDoc(doc(db, routePath()), { status: "completed", completedAt: now() }));
    await assertFails(updateDoc(doc(db, routePath()), { status: "archived", archivedAt: now() }));
    const batch = writeBatch(db);
    batch.update(ref, { state: "finished", changedAt: now(), transitionCount: 1 });
    batch.update(doc(db, routePath()), { status: "completed", completedAt: now() });
    await assertSucceeds(batch.commit());
    expect((await getDoc(ref)).data()!.state).toBe("finished");
    expect((await getDoc(doc(db, routePath()))).data()!.status).toBe("completed");
  });

  it("paused execution also protects archive, while other routes remain independently editable", async () => {
    const { db, ref } = await started();
    await updateDoc(ref, { state: "paused", changedAt: now(), transitionCount: 1 });
    await assertFails(updateDoc(doc(db, routePath()), { status: "archived", archivedAt: now() }));
    await assertSucceeds(setDoc(doc(db, routePath("alice", "r2")), route("r2")));
    await assertSucceeds(updateDoc(doc(db, routePath("alice", "r2")), { status: "archived", archivedAt: now() }));
    const batch = writeBatch(db);
    batch.update(ref, { state: "finished", changedAt: now(), transitionCount: 2 });
    batch.update(doc(db, routePath()), { status: "completed", completedAt: now() });
    await assertSucceeds(batch.commit());
  });

  it("reopen keeps finished session; subsequent explicit Start creates a new session", async () => {
    const { db, ref } = await started();
    const batch = writeBatch(db);
    batch.update(ref, { state: "finished", changedAt: now(), transitionCount: 1 });
    batch.update(doc(db, routePath()), { status: "completed", completedAt: now() });
    await batch.commit();
    await assertSucceeds(updateDoc(doc(db, routePath()), { status: "active" }));
    expect((await getDoc(ref)).data()!.state).toBe("finished");
    await assertSucceeds(setDoc(ref, execution({ id: "session2" })));
    expect((await getDoc(ref)).data()!.id).toBe("session2");
  });

  it("closed or absent routes cannot Start or Resume", async () => {
    const { db, ref } = await started();
    const batch = writeBatch(db);
    batch.update(ref, { state: "finished", changedAt: now(), transitionCount: 1 });
    batch.update(doc(db, routePath()), { status: "completed", completedAt: now() });
    await batch.commit();
    await assertFails(setDoc(ref, execution({ id: "session2" })));
    await assertFails(updateDoc(ref, { state: "active", transitionCount: 2, changedAt: now() }));
  });
});

describe("ownership", () => {
  it("lets the owner create and read a route", async () => {
    await assertSucceeds(setDoc(doc(alice(), routePath()), route()));
    await assertSucceeds(getDoc(doc(alice(), routePath())));
  });

  it("denies other users and signed-out clients", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => setDoc(doc(ctx.firestore(), routePath()), route()));
    await assertFails(getDoc(doc(bob(), routePath())));
    await assertFails(setDoc(doc(bob(), routePath()), route()));
    await assertFails(setDoc(doc(bob(), `${routePath()}/stops/s9`), stop("s9")));
    await assertFails(getDoc(doc(anon(), routePath())));
    await assertFails(setDoc(doc(anon(), routePath("alice", "r2")), route("r2")));
  });
});

describe("route schema", () => {
  it("allows a rich warehouse close-out by validating only changed nested values", async () => {
    const db = alice();
    const ref = doc(db, routePath());
    const warehouse = { label: "Warehouse", address, located: { point: { latitude: 48.42, longitude: -123.36 }, source: "driverPin" } };
    await assertSucceeds(setDoc(ref, route("r1", { start: warehouse })));
    await assertSucceeds(updateDoc(ref, { inputRevision: 2, status: "active", startedAt: now(), appliedRequestID: "accepted-proposal", appliedRevision: 2, latestArrivalMinute: 1020, plannedDistance: { meters: 1200, provider: "google", calculatedAt: now(), expiresAt: inDays(1) } }));
    await assertSucceeds(updateDoc(ref, { status: "completed", completedAt: now(), summary: { delivered: 1, failed: 0, skipped: 0, excluded: 0, pending: 0, stopCount: 1, packageCount: 1, firstOutcomeAt: now(), lastOutcomeAt: now() } }));
    await assertSucceeds(updateDoc(ref, { name: "Renamed completed route", inputRevision: 3 }));
    const saved = (await getDoc(ref)).data()!;
    expect(saved.start.address.unit).toBe("204");
    expect(saved.summary.delivered).toBe(1);
    expect(saved.status).toBe("completed");
  });

  it("metadata updates cannot bypass changed nested data or root constraints", async () => {
    const db = alice();
    const ref = doc(db, routePath());
    const warehouse = { label: "Warehouse", address, located: { point: { latitude: 48.42, longitude: -123.36 }, source: "driverPin" } };
    await assertSucceeds(setDoc(ref, route("r1", { start: warehouse, latestArrivalMinute: 1020 })));
    for (const changes of [
      { name: "Edited", "start.address.civicNumber": 123 },
      { name: "Edited", "start.address.unexpected": true },
      { name: "Edited", "start.located.point.latitude": 91 },
      { name: "Edited", end: { label: "Bad", located: { point: { latitude: 48.4, longitude: -123.4 }, source: "providerGeocode", expiresAt: inDays(40) } } },
      { name: "Edited", breakRule: { earliestStartMinute: 600, latestStartMinute: 500, durationSeconds: 900 } },
      { name: "Edited", plannedDistance: { meters: 1000, provider: "google", calculatedAt: now(), expiresAt: inDays(3) } },
      { name: "Edited", summary: { delivered: 1, failed: 0, skipped: 0, excluded: 0, pending: "invalid", stopCount: 1, packageCount: 1 } },
      { name: "Edited", returnToStart: false },
      { name: "", inputRevision: 2 },
      { name: "Edited", timeZoneID: "invalid" },
      { name: "Edited", unexpected: true },
    ]) await assertFails(updateDoc(ref, changes));
    await assertSucceeds(updateDoc(ref, { name: "Valid metadata", inputRevision: 2 }));
  });

  it("accepts and removes a latest arrival limit, but rejects invalid times and missing warehouses", async () => {
    const ref = doc(alice(), routePath());
    const base = route();
    await assertSucceeds(setDoc(ref, { ...base, latestArrivalMinute: 1020 }));
    await assertSucceeds(setDoc(ref, { ...base, latestArrivalMinute: 1500 }));
    await assertSucceeds(setDoc(ref, base));
    for (const minute of [480, 479, 2880, -1, 1020.5, "17:00"]) await assertFails(setDoc(ref, { ...base, latestArrivalMinute: minute }));
    const withoutWarehouse = { ...base, latestArrivalMinute: 1020 };
    delete (withoutWarehouse as Record<string, unknown>).start;
    await assertFails(setDoc(ref, withoutWarehouse));
    await assertFails(setDoc(ref, { ...base, latestArrivalMinute: 1020, returnToStart: false }));
    await assertSucceeds(setDoc(ref, { ...base, latestArrivalMinute: 1020, returnToStart: false, end: { label: "Other depot" } }));
  });

  it("rejects unknown fields, bad zones, decreasing revisions and changed creation time", async () => {
    await assertFails(setDoc(doc(alice(), routePath()), route("r1", { hacked: true })));
    await assertFails(setDoc(doc(alice(), routePath()), route("r1", { timeZoneID: "Europe/Paris" })));
    await assertFails(setDoc(doc(alice(), routePath()), route("r1", { id: "other" })));
    await assertSucceeds(setDoc(doc(alice(), routePath()), route("r1", { inputRevision: 5 })));
    await assertFails(updateDoc(doc(alice(), routePath()), { inputRevision: 4 }));
    await assertSucceeds(updateDoc(doc(alice(), routePath()), { inputRevision: 6, name: "Renamed" }));
    await assertFails(updateDoc(doc(alice(), routePath()), { createdAt: Timestamp.fromMillis(0) }));
  });

  it("never allows deleting a route (archive instead)", async () => {
    await assertSucceeds(setDoc(doc(alice(), routePath()), route()));
    await assertFails(deleteDoc(doc(alice(), routePath())));
  });

  it("requires provider coordinates to expire within 31 days", async () => {
    const google = (days: number | null) => ({ label: "Depot", located: { point: { latitude: 48.4, longitude: -123.3 }, source: "providerGeocode", ...(days === null ? {} : { expiresAt: inDays(days) }) } });
    await assertSucceeds(setDoc(doc(alice(), routePath()), route("r1", { start: google(30) })));
    await assertFails(setDoc(doc(alice(), routePath("alice", "r2")), route("r2", { start: google(60) })));
    await assertFails(setDoc(doc(alice(), routePath("alice", "r3")), route("r3", { start: google(null) })));
  });
});

describe("stops and packages", () => {
  it("accepts valid documents", async () => {
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/stops/s1`), stop()));
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/packages/p1`), pkg()));
  });

  it("only allows 'verified' with a Google building-level resolution", async () => {
    const demo = stop("s2", { resolution: { provider: "demo", match: "synthetic", resolvedAt: now(), located: { point: { latitude: 48.4, longitude: -123.3 }, source: "demoSynthetic" } } });
    await assertFails(setDoc(doc(alice(), `${routePath()}/stops/s2`), demo));
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/stops/s2`), { ...demo, addressStatus: "demoSynthetic" }));
    const centroid = stop("s3", { resolution: { provider: "google", match: "postalArea", resolvedAt: now() } });
    await assertFails(setDoc(doc(alice(), `${routePath()}/stops/s3`), centroid));
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/stops/s3`), { ...centroid, addressStatus: "needsReview" }));
  });

  it("validates time windows", async () => {
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/stops/s1`), stop("s1", { timeWindow: { kind: "hard", startMinute: 540, endMinute: 600 } })));
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/stops/s2`), stop("s2", { timeWindow: { kind: "softDeadline", endMinute: 600 } })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/stops/s3`), stop("s3", { timeWindow: { kind: "hard", endMinute: 600 } })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/stops/s4`), stop("s4", { timeWindow: { kind: "hard", startMinute: 700, endMinute: 600 } })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/stops/s5`), stop("s5", { timeWindow: { kind: "priority", endMinute: 600 } })));
  });

  it("rejects malformed packages", async () => {
    await assertFails(setDoc(doc(alice(), `${routePath()}/packages/p2`), pkg("p2", { size: "gigantic" })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/packages/p3`), pkg("p3", { stopID: "../../evil" })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/packages/p4`), pkg("p4", { notes: "x".repeat(1001) })));
  });
});

describe("delivery outcomes are append-only", () => {
  const path = `${routePath()}/outcomes/o1`;

  it("can be created and voided once, never edited or deleted", async () => {
    await assertSucceeds(setDoc(doc(alice(), path), outcome()));
    await assertFails(updateDoc(doc(alice(), path), { kind: "failed" }));
    await assertFails(deleteDoc(doc(alice(), path)));
    await assertSucceeds(updateDoc(doc(alice(), path), { voidedAt: now() }));
    await assertFails(updateDoc(doc(alice(), path), { voidedAt: now() }));
  });

  it("allows an identical offline replay but not un-voiding", async () => {
    const data = outcome();
    await assertSucceeds(setDoc(doc(alice(), path), data));
    await assertSucceeds(setDoc(doc(alice(), path), data));
    await assertSucceeds(updateDoc(doc(alice(), path), { voidedAt: now() }));
    await assertFails(setDoc(doc(alice(), path), data));
  });

  it("cannot be created already voided or far in the future", async () => {
    await assertFails(setDoc(doc(alice(), `${routePath()}/outcomes/o2`), outcome("o2", { voidedAt: now() })));
    await assertFails(setDoc(doc(alice(), `${routePath()}/outcomes/o3`), outcome("o3", { recordedAt: inDays(2) })));
  });

  it("works inside a batch with other writes", async () => {
    const db = alice();
    const batch = writeBatch(db);
    batch.set(doc(db, `${routePath()}/outcomes/o4`), outcome("o4"));
    batch.set(doc(db, `${routePath()}/outcomes/o5`), outcome("o5", { kind: "failed", reason: "noOneHome" }));
    await assertSucceeds(batch.commit());
  });
});

describe("generalized location work", () => {
  it("copies a new route, stop, package and associated task in one batch", async () => {
    const db = alice();
    const batch = writeBatch(db);
    batch.set(doc(db, routePath()), route());
    batch.set(doc(db, `${routePath()}/stops/s1`), stop());
    batch.set(doc(db, `${routePath()}/packages/p1`), pkg());
    batch.set(doc(db, `${routePath()}/tasks/t1`), task("t1", { packageID: "p1" }));
    await assertSucceeds(batch.commit());
  });

  it("requires a same-batch revision advance for task create, update and delete", async () => {
    await seedWork();
    const db = alice();
    const ref = doc(db, `${routePath()}/tasks/t2`);
    await assertFails(setDoc(ref, task("t2", { kind: "checklist", required: false })));
    let batch = revisionBatch(db, 2);
    batch.set(ref, task("t2", { kind: "checklist", required: false }));
    await assertSucceeds(batch.commit());
    await assertFails(updateDoc(ref, { required: true }));
    batch = revisionBatch(db, 3);
    batch.update(ref, { required: true });
    await assertSucceeds(batch.commit());
    await assertFails(deleteDoc(ref));
    batch = revisionBatch(db, 4);
    batch.delete(ref);
    await assertSucceeds(batch.commit());
  });

  it("keeps a persisted task's target, kind and package association immutable", async () => {
    await seedWork();
    const db = alice();
    await setDoc(doc(db, `${routePath()}/stops/s2`), stop("s2"));
    for (const change of [{ stopID: "s2" }, { kind: "checklist" }, { packageID: "p1" }]) {
      const batch = revisionBatch(db);
      batch.update(doc(db, `${routePath()}/tasks/t1`), change);
      await assertFails(batch.commit());
    }
    const batch = revisionBatch(db);
    batch.update(doc(db, `${routePath()}/tasks/t1`), { title: "Updated instruction", instructions: "Ask reception", orderRank: 3, required: false });
    await assertSucceeds(batch.commit());
  });

  it("rejects unsupported definitions, reserved identities and missing parents", async () => {
    await seedWork();
    const db = alice();
    for (const extra of [{ kind: "delivery" }, { kind: "future" }, { schemaVersion: 2 }, { required: "yes" }, { orderRank: -1 }, { orderRank: 0.5 }, { title: "x".repeat(121) }, { instructions: "x".repeat(2001) }, { stopID: "missing" }, { unexpected: true }]) {
      const batch = revisionBatch(db);
      batch.set(doc(db, `${routePath()}/tasks/t2`), task("t2", extra));
      await assertFails(batch.commit());
    }
    const batch = revisionBatch(db);
    batch.set(doc(db, `${routePath()}/tasks/delivery_p1`), task("delivery_p1"));
    await assertFails(batch.commit());
    await assertFails(setDoc(doc(db, `${routePath("alice", "missing")}/tasks/t1`), task()));
  });

  it("validates package association independently from the task outcome target", async () => {
    await seedWork({ packageID: "p1" });
    const db = alice();
    for (const packageID of ["missing", "../../p1"]) {
      const batch = revisionBatch(db);
      batch.set(doc(db, `${routePath()}/tasks/t2`), task("t2", { packageID }));
      await assertFails(batch.commit());
    }
    await env.withSecurityRulesDisabled(async (ctx) => setDoc(doc(ctx.firestore(), `${routePath()}/packages/p2`), pkg("p2", { stopID: "s2" })));
    let batch = revisionBatch(db);
    batch.set(doc(db, `${routePath()}/tasks/t2`), task("t2", { packageID: "p2" }));
    await assertFails(batch.commit());
    batch = revisionBatch(db);
    batch.set(doc(db, `${routePath()}/outcomes/o1`), taskEvent());
    await assertSucceeds(batch.commit());
  });

  it("requires a revision advance for standalone outcomes and accepts supported dispositions", async () => {
    await seedWork();
    const db = alice();
    await assertFails(setDoc(doc(db, `${routePath()}/outcomes/o1`), taskEvent()));
    for (const [index, kind] of ["completed", "failed", "skipped", "requeued", "excluded"].entries()) {
      const batch = revisionBatch(db, index + 2);
      const id = `o${index + 1}`;
      batch.set(doc(db, `${routePath()}/outcomes/${id}`), taskEvent(id, { kind }));
      await assertSucceeds(batch.commit());
    }
  });

  it("rejects unknown, mismatched or inappropriate outcome targets", async () => {
    await seedWork();
    const db = alice();
    for (const extra of [{ taskID: "missing" }, { stopID: "s2" }, { kind: "delivered" }, { schemaVersion: 1 }, { packageID: "p1" }, { taskID: "delivery_p1", kind: "delivered" }, { kind: "future" }]) {
      const batch = revisionBatch(db);
      batch.set(doc(db, `${routePath()}/outcomes/o1`), taskEvent("o1", extra));
      await assertFails(batch.commit());
    }
  });

  it("schema 2 delivery events require matching package identity for every disposition", async () => {
    await seedWork();
    const db = alice();
    for (const [index, kind] of ["delivered", "failed", "skipped", "requeued", "excluded"].entries()) {
      const batch = revisionBatch(db, index + 2);
      const id = `o${index + 1}`;
      batch.set(doc(db, `${routePath()}/outcomes/${id}`), taskEvent(id, { taskID: "delivery_p1", packageID: "p1", kind }));
      await assertSucceeds(batch.commit());
    }
    for (const extra of [{ kind: "completed" }, { taskID: "delivery_p2" }, { stopID: "s2" }]) {
      const batch = revisionBatch(db, 7);
      batch.set(doc(db, `${routePath()}/outcomes/bad`), taskEvent("bad", { taskID: "delivery_p1", packageID: "p1", kind: "delivered", ...extra }));
      await assertFails(batch.commit());
    }
  });

  it("delivery projection IDs support the longest existing package identity", async () => {
    await seedWork();
    const db = alice();
    const packageID = "p".repeat(64);
    const batch = revisionBatch(db);
    batch.set(doc(db, `${routePath()}/packages/${packageID}`), pkg(packageID));
    batch.set(doc(db, `${routePath()}/outcomes/o1`), taskEvent("o1", { taskID: `delivery_${packageID}`, packageID, kind: "delivered" }));
    await assertSucceeds(batch.commit());
  });

  it("schema 2 outcomes are immutable, identical replay is allowed, and Undo advances revision", async () => {
    await seedWork();
    const db = alice();
    const ref = doc(db, `${routePath()}/outcomes/o1`);
    const data = taskEvent();
    let batch = revisionBatch(db, 2);
    batch.set(ref, data);
    await assertSucceeds(batch.commit());
    await assertSucceeds(setDoc(ref, data));
    await assertFails(updateDoc(ref, { kind: "failed" }));
    await assertFails(updateDoc(ref, { voidedAt: now() }));
    batch = revisionBatch(db, 3);
    batch.update(ref, { voidedAt: now() });
    await assertSucceeds(batch.commit());
    await assertFails(setDoc(ref, data));
    await assertFails(deleteDoc(ref));
  });

  it("allows legacy package outcomes without imposing new-client revision rules", async () => {
    await seedWork();
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/outcomes/o1`), outcome()));
    await assertSucceeds(updateDoc(doc(alice(), `${routePath()}/outcomes/o1`), { voidedAt: now() }));
  });

  it("accepts additive required-work summary counters and rejects inconsistent totals", async () => {
    const summary = { delivered: 1, failed: 0, skipped: 0, excluded: 0, pending: 0, stopCount: 1, packageCount: 1, work: { required: 2, optional: 1, completed: 1, failed: 0, deferred: 1, excluded: 0, pending: 0, unsupported: 0 } };
    const db = alice();
    await assertSucceeds(setDoc(doc(db, routePath()), route("r1", { summary })));
    await assertFails(updateDoc(doc(db, routePath()), { summary: { ...summary, work: { ...summary.work, required: 3 } } }));
    await assertFails(updateDoc(doc(db, routePath()), { summary: { ...summary, work: { ...summary.work, optional: -1 } } }));
  });

  it("preserves legacy close-out for a complete warehouse address and accepted proposal", async () => {
    const summary = { delivered: 1, failed: 0, skipped: 0, excluded: 0, pending: 0, stopCount: 1, packageCount: 1, firstOutcomeAt: now(), lastOutcomeAt: now() };
    const place = { label: "Warehouse", address, placeID: "google-place", located: { point: { latitude: 48.4, longitude: -123.3 }, source: "providerGeocode", expiresAt: inDays(30) } };
    const full = route("r1", { summary, start: place, status: "completed", appliedRequestID: "req1", appliedRevision: 1, startedAt: now(), completedAt: now() });
    await assertSucceeds(setDoc(doc(alice(), routePath()), full));
    await assertSucceeds(updateDoc(doc(alice(), routePath()), { name: "Updated completed route", inputRevision: 2 }));
  });
});

describe("server-owned state", () => {
  it("lets the owner read jobs but never write them", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => setDoc(doc(ctx.firestore(), "users/alice/optimizationRequests/j1"), { status: "succeeded" }));
    await assertSucceeds(getDoc(doc(alice(), "users/alice/optimizationRequests/j1")));
    await assertFails(getDoc(doc(bob(), "users/alice/optimizationRequests/j1")));
    await assertFails(setDoc(doc(alice(), "users/alice/optimizationRequests/j2"), { status: "succeeded", proposal: {} }));
    await assertFails(updateDoc(doc(alice(), "users/alice/optimizationRequests/j1"), { status: "failed" }));
  });

  it("hides usage counters, locks and system documents", async () => {
    await assertFails(getDoc(doc(alice(), "users/alice/usage/2026-10-05")));
    await assertFails(setDoc(doc(alice(), "users/alice/usage/2026-10-05"), { geocodes: 0 }));
    await assertFails(setDoc(doc(alice(), "users/alice/optimizationLocks/r1"), { requestId: "x" }));
    await assertFails(getDoc(doc(alice(), "system/usage/months/2026-10")));
  });
});

describe("photos and user settings", () => {
  it("requires the canonical storage path", async () => {
    const photo = { id: "ph1", schemaVersion: 1, stopID: "s1", packageIDs: ["p1"], storagePath: "users/alice/routes/r1/pod/ph1.jpg", contentType: "image/jpeg", byteSize: 1000, capturedAt: now() };
    await assertSucceeds(setDoc(doc(alice(), `${routePath()}/photos/ph1`), photo));
    await assertFails(setDoc(doc(alice(), `${routePath()}/photos/ph2`), { ...photo, id: "ph2", storagePath: "users/bob/routes/r1/pod/ph2.jpg" }));
  });

  it("validates user settings and forbids self-deleting the user document", async () => {
    const user = { schemaVersion: 1, createdAt: now(), updatedAt: now(), settings: { navigationApp: "appleMaps", distanceUnit: "kilometres", defaultServiceSeconds: 120, batchScanDefault: false } };
    await assertSucceeds(setDoc(doc(alice(), "users/alice"), user));
    await assertFails(setDoc(doc(alice(), "users/alice"), { ...user, settings: { ...user.settings, navigationApp: "waze" } }));
    await assertFails(deleteDoc(doc(alice(), "users/alice")));
    await assertFails(setDoc(doc(bob(), "users/alice"), user));
  });
});

describe("rules file sanity", () => {
  it("has no blanket allow", () => {
    expect(readFileSync("firestore.rules", "utf8")).not.toMatch(/allow read, write: if true/);
  });
});

describe("durable command receipts", () => {
  function receipt(id = "command1", extra: Record<string, unknown> = {}) {
    return { id, schemaVersion: 1, accountID: "alice", routeID: "r1", sequence: 1,
      payloadDigest: "a".repeat(64), baseRevision: 1, appliedRevision: 2, appliedAt: serverTimestamp(), ...extra };
  }
  it("atomically creates a work effect, revision and immutable receipt", async () => {
    await seedWork();
    const db = alice();
    const batch = revisionBatch(db);
    batch.set(doc(db, `${routePath()}/outcomes/o1`), taskEvent());
    batch.set(doc(db, `${routePath()}/mutationReceipts/command1`), receipt());
    await assertSucceeds(batch.commit());
    const ref = doc(db, `${routePath()}/mutationReceipts/command1`);
    const stored = (await getDoc(ref)).data()!;
    expect(stored.appliedRevision).toBe(2);
    await assertSucceeds(setDoc(ref, stored));
    await assertFails(updateDoc(ref, { payloadDigest: "b".repeat(64) }));
    await assertFails(updateDoc(ref, { sequence: 2 }));
    await assertFails(deleteDoc(ref));
  });
  it("rejects another account and receipts unrelated to the route revision", async () => {
    await seedWork();
    const path = `${routePath()}/mutationReceipts/command1`;
    await assertFails(setDoc(doc(bob(), path), receipt()));
    await assertFails(getDoc(doc(bob(), path)));
    await assertFails(setDoc(doc(anon(), path), receipt()));
    await assertFails(setDoc(doc(alice(), path), receipt())); // root is still revision 1
    await assertFails(setDoc(doc(alice(), path), receipt("command1", { appliedRevision: 1, accountID: "bob" })));
  });
  it("validates receipt identity, schema, digest and monotonic counters", async () => {
    await seedWork();
    const db = alice();
    for (const invalid of [
      { id: "another-command" }, { schemaVersion: 2 }, { routeID: "r2" },
      { sequence: 0 }, { sequence: 1.5 }, { payloadDigest: "short" }, { payloadDigest: "Z".repeat(64) },
      { baseRevision: -1 }, { baseRevision: 3 }, { appliedRevision: 0 }, { note: "Private address" },
    ]) {
      const batch = revisionBatch(db);
      batch.set(doc(db, `${routePath()}/mutationReceipts/command1`), receipt("command1", invalid));
      await assertFails(batch.commit());
    }
    expect((await getDoc(doc(db, routePath()))).data()!.inputRevision).toBe(1);
  });
  it("fits the rules read budget for six distinct task outcomes plus a receipt", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, routePath()), route());
      for (let n = 0; n < 6; n++) {
        await setDoc(doc(db, `${routePath()}/stops/s${n}`), stop(`s${n}`));
        await setDoc(doc(db, `${routePath()}/tasks/t${n}`), task(`t${n}`, { stopID: `s${n}` }));
      }
    });
    const db = alice();
    const batch = revisionBatch(db);
    for (let n = 0; n < 6; n++) {
      batch.set(doc(db, `${routePath()}/outcomes/o${n}`), taskEvent(`o${n}`, { taskID: `t${n}`, stopID: `s${n}` }));
    }
    batch.set(doc(db, `${routePath()}/mutationReceipts/command1`), receipt());
    await assertSucceeds(batch.commit());
  });
});
