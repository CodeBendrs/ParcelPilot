/**
 * Hard application-level usage limits, enforced in Firestore transactions *before* any paid provider
 * call. Counters live in server-only documents (clients cannot read or write them):
 *
 *   users/{uid}/usage/{YYYY-MM-DD}   per-user daily counters (UTC day)
 *   system/usage/months/{YYYY-MM}    project-wide monthly counters (UTC month)
 *
 * Billing alerts in Google Cloud are recommended in addition, but they are not a spending cap; these
 * counters are. A reservation is released only when the provider certainly did not bill the attempt.
 */
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import { errors } from "./errors";

export interface Limits {
  maxEligibleStops: number;
  dailyGeocodesPerUser: number;
  dailyOptimizationsPerUser: number;
  dailyShipmentsPerUser: number;
  monthlyGeocodeBudget: number;
  monthlyShipmentBudget: number;
  dailySuggestionsPerUser: number;
  monthlySuggestionBudget: number;
}

export interface Reservation {
  dayPath: string;
  monthPath: string;
  fields: Record<string, number>;
}

export function dayKey(now: Date): string {
  return now.toISOString().slice(0, 10);
}

export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

export async function reserveGeocode(db: Firestore, uid: string, limits: Limits, now: Date): Promise<Reservation> {
  return reserve(db, uid, now, { geocodes: 1 }, (day, month) => {
    if ((day.geocodes ?? 0) + 1 > limits.dailyGeocodesPerUser) throw errors.quotaExceeded("Daily address lookup", "It resets at midnight UTC.");
    if ((month.geocodes ?? 0) + 1 > limits.monthlyGeocodeBudget) throw errors.quotaExceeded("Monthly address lookup", "The app's monthly budget is used up.");
  });
}

export async function reserveSuggestion(db: Firestore, uid: string, limits: Limits, now: Date): Promise<Reservation> {
  return reserve(db, uid, now, { suggestions: 1 }, (day, month) => {
    if ((day.suggestions ?? 0) + 1 > limits.dailySuggestionsPerUser) throw errors.quotaExceeded("Daily address suggestion", "It resets at midnight UTC. You can still type the full address.");
    if ((month.suggestions ?? 0) + 1 > limits.monthlySuggestionBudget) throw errors.quotaExceeded("Monthly address suggestion", "The app's monthly budget is used up. You can still type the full address.");
  });
}

export async function reserveOptimization(db: Firestore, uid: string, shipments: number, limits: Limits, now: Date): Promise<Reservation> {
  return reserve(db, uid, now, { optimizations: 1, shipments }, (day, month) => {
    if ((day.optimizations ?? 0) + 1 > limits.dailyOptimizationsPerUser) throw errors.quotaExceeded("Daily optimization", "It resets at midnight UTC.");
    if ((day.shipments ?? 0) + shipments > limits.dailyShipmentsPerUser) throw errors.quotaExceeded("Daily stop-optimization", "It resets at midnight UTC.");
    if ((month.shipments ?? 0) + shipments > limits.monthlyShipmentBudget) throw errors.quotaExceeded("Monthly optimization", "The app's monthly budget is used up.");
  });
}

async function reserve(
  db: Firestore,
  uid: string,
  now: Date,
  fields: Record<string, number>,
  check: (day: Record<string, number>, month: Record<string, number>) => void,
): Promise<Reservation> {
  const dayRef = db.doc(`users/${uid}/usage/${dayKey(now)}`);
  const monthRef = db.doc(`system/usage/months/${monthKey(now)}`);
  await db.runTransaction(async (tx) => {
    const [day, month] = await Promise.all([tx.get(dayRef), tx.get(monthRef)]);
    check((day.data() ?? {}) as Record<string, number>, (month.data() ?? {}) as Record<string, number>);
    const inc = Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, FieldValue.increment(v)]));
    tx.set(dayRef, { ...inc, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    tx.set(monthRef, { ...inc, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  });
  return { dayPath: dayRef.path, monthPath: monthRef.path, fields };
}

/** Returns reserved units when the provider certainly did not bill (validation errors, auth errors, no call made). */
export async function release(db: Firestore, r: Reservation): Promise<void> {
  const dec = Object.fromEntries(Object.entries(r.fields).map(([k, v]) => [k, FieldValue.increment(-v)]));
  const batch = db.batch();
  batch.set(db.doc(r.dayPath), dec, { merge: true });
  batch.set(db.doc(r.monthPath), dec, { merge: true });
  await batch.commit();
}
