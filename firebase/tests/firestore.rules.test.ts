/**
 * Firestore security rules tests (run against the emulator: `npm run test:rules`).
 * Documents are shaped exactly like the iOS app writes them (Swift Codable via the Firestore encoder).
 */
import { assertFails, assertSucceeds, initializeTestEnvironment, type RulesTestEnvironment } from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, setDoc, Timestamp, updateDoc, writeBatch } from "firebase/firestore";
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

const routePath = (uid = "alice", id = "r1") => `users/${uid}/routes/${id}`;

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
