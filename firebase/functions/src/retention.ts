/**
 * Daily purge of expired provider content (Google Maps Content retention):
 *  - optimization jobs/proposals past `expiresAt` (24 h) — also covered by a Firestore TTL policy;
 *  - geocoded stop coordinates past `resolution.located.expiresAt` (30 days) — the place ID is kept so
 *    the app can refresh the coordinate when needed;
 *  - route start/end coordinates and planned distances past their expiry.
 * Driver-owned data (addresses, notes, packages, outcomes, driver pins) is never touched.
 */
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";

export async function purgeExpiredProviderContent(db: Firestore, now: Date, pageSize = 300): Promise<Record<string, number>> {
  const cutoff = Timestamp.fromDate(now);
  const counts = { jobs: 0, stopCoordinates: 0, routeStarts: 0, routeEnds: 0, plannedDistances: 0 };

  const drain = async (query: FirebaseFirestore.Query, apply: (batch: FirebaseFirestore.WriteBatch, ref: FirebaseFirestore.DocumentReference) => void, key: keyof typeof counts) => {
    for (;;) {
      const snap = await query.limit(pageSize).get();
      if (snap.empty) return;
      const batch = db.batch();
      snap.docs.forEach((d) => apply(batch, d.ref));
      await batch.commit();
      counts[key] += snap.size;
      if (snap.size < pageSize) return;
    }
  };

  await drain(db.collectionGroup("optimizationRequests").where("expiresAt", "<", cutoff), (b, r) => b.delete(r), "jobs");
  await drain(db.collectionGroup("stops").where("resolution.located.expiresAt", "<", cutoff), (b, r) => b.update(r, { "resolution.located": FieldValue.delete() }), "stopCoordinates");
  await drain(db.collectionGroup("routes").where("start.located.expiresAt", "<", cutoff), (b, r) => b.update(r, { "start.located": FieldValue.delete() }), "routeStarts");
  await drain(db.collectionGroup("routes").where("end.located.expiresAt", "<", cutoff), (b, r) => b.update(r, { "end.located": FieldValue.delete() }), "routeEnds");
  await drain(db.collectionGroup("routes").where("plannedDistance.expiresAt", "<", cutoff), (b, r) => b.update(r, { plannedDistance: FieldValue.delete() }), "plannedDistances");
  return counts;
}
