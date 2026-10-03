/**
 * `resolveAddress` core: authenticated, validated, quota-checked address resolution. Returns
 * candidates only — the app compares them with the label (MatchAssessor) and the driver decides.
 * Results are Google Maps Content: coordinates may be cached ≤ 30 days (expiresAt) and shown on a
 * Google map only. Inputs and results are never logged.
 */
import type { Firestore } from "firebase-admin/firestore";
import { AppError, errors } from "./errors";
import { release, reserveGeocode, type Limits } from "./quota";
import type { GeocodeCandidateOut, Geocoder } from "./providers/interfaces";
import { parseInput, ResolveAddressInput } from "./validation";

export interface ResolveDeps {
  db: Firestore;
  geocoder: Geocoder;
  limits: Limits;
  now: () => Date;
}

export interface ResolveResult {
  provider: "google" | "emulatorFake";
  candidates: GeocodeCandidateOut[];
  resolvedAt: string;
  coordinatesExpireAt: string;
}

export const COORDINATE_LIFETIME_MS = 30 * 24 * 3600_000;

export async function resolveAddress(deps: ResolveDeps, uid: string, raw: unknown): Promise<ResolveResult> {
  let input: ResolveAddressInput;
  try {
    input = parseInput(ResolveAddressInput, raw);
  } catch (e) {
    throw errors.invalidInput((e as Error).message);
  }
  const now = deps.now();
  const reservation = await reserveGeocode(deps.db, uid, deps.limits, now);
  try {
    const candidates = await deps.geocoder.geocode(input);
    // Canada only: other countries are dropped (the app explains "not found" to the driver).
    const canadian = candidates.filter((c) => !c.countryCode || c.countryCode.toUpperCase() === "CA");
    return {
      provider: deps.geocoder.provider,
      candidates: canadian,
      resolvedAt: now.toISOString(),
      coordinatesExpireAt: new Date(now.getTime() + COORDINATE_LIFETIME_MS).toISOString(),
    };
  } catch (e) {
    const err = e instanceof AppError ? e : errors.providerUnavailable("geocoder error");
    if (!err.possiblyBilled) await release(deps.db, reservation).catch(() => undefined);
    throw err;
  }
}
