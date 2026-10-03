/**
 * ParcelPilot Cloud Functions (2nd gen, northamerica-northeast1).
 *
 * Every callable: requires Firebase Auth, enforces App Check in production (param ENFORCE_APP_CHECK),
 * validates input, scopes all data access to users/{uid}, and enforces hard usage limits before any
 * paid provider call. Nothing here logs addresses, tracking numbers, notes or OCR text.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { defineBoolean, defineInt, defineString } from "firebase-functions/params";
import { setGlobalOptions } from "firebase-functions/v2";
import { onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { deleteAccount as deleteAccountCore } from "./account";
import { assertMayUsePaidFeatures } from "./accountChecks";
import { AppError, errors, toHttpsError } from "./errors";
import { requestOptimization as requestOptimizationCore } from "./optimization/run";
import { FakeGeocoder, FakeSuggester, FakeTourOptimizer } from "./providers/fake";
import { GoogleGeocoder, GooglePlacesSuggester, GoogleRouteOptimizer } from "./providers/google";
import type { AddressSuggester, Geocoder, TourOptimizer } from "./providers/interfaces";
import type { Limits } from "./quota";
import { resolveAddress as resolveAddressCore } from "./resolveAddress";
import { purgeExpiredProviderContent as purgeCore } from "./retention";
import { suggestAddresses as suggestAddressesCore } from "./suggestAddresses";

initializeApp();

// Least-privilege runtime identity (see docs/COST_AND_SETUP.md). Read at deploy time from
// functions/.env.<projectId>; when unset, Firebase's default service account is used.
if (process.env.RUNTIME_SERVICE_ACCOUNT) {
  setGlobalOptions({ serviceAccount: process.env.RUNTIME_SERVICE_ACCOUNT });
}

export const REGION = "northamerica-northeast1";

const ENFORCE_APP_CHECK = defineBoolean("ENFORCE_APP_CHECK", { default: true, description: "Reject callable requests without a valid App Check token. Keep true in production." });
const PROVIDER_MODE = defineString("PROVIDER_MODE", { default: "google", description: "google (production) or emulator-fake (Firebase Emulator Suite only; refused elsewhere)." });
const MAX_ELIGIBLE_STOPS = defineInt("MAX_ELIGIBLE_STOPS", { default: 200, description: "Product limit: eligible stops per optimization." });
const DAILY_GEOCODES_PER_USER = defineInt("DAILY_GEOCODES_PER_USER", { default: 400 });
const DAILY_OPTIMIZATIONS_PER_USER = defineInt("DAILY_OPTIMIZATIONS_PER_USER", { default: 25 });
const DAILY_SHIPMENTS_PER_USER = defineInt("DAILY_SHIPMENTS_PER_USER", { default: 2000 });
const MONTHLY_GEOCODE_BUDGET = defineInt("MONTHLY_GEOCODE_BUDGET", { default: 9000, description: "Project-wide hard cap (Geocoding free usage is 10,000/month)." });
const MONTHLY_SHIPMENT_BUDGET = defineInt("MONTHLY_SHIPMENT_BUDGET", { default: 4500, description: "Project-wide hard cap (Single Vehicle Routing free usage is 5,000 shipments/month)." });
const DAILY_SUGGESTIONS_PER_USER = defineInt("DAILY_SUGGESTIONS_PER_USER", { default: 500 });
const MONTHLY_SUGGESTION_BUDGET = defineInt("MONTHLY_SUGGESTION_BUDGET", { default: 9000, description: "Project-wide hard cap (Places Autocomplete free usage is 10,000 requests/month)." });

function limits(): Limits {
  return {
    maxEligibleStops: MAX_ELIGIBLE_STOPS.value(),
    dailyGeocodesPerUser: DAILY_GEOCODES_PER_USER.value(),
    dailyOptimizationsPerUser: DAILY_OPTIMIZATIONS_PER_USER.value(),
    dailyShipmentsPerUser: DAILY_SHIPMENTS_PER_USER.value(),
    monthlyGeocodeBudget: MONTHLY_GEOCODE_BUDGET.value(),
    monthlyShipmentBudget: MONTHLY_SHIPMENT_BUDGET.value(),
    dailySuggestionsPerUser: DAILY_SUGGESTIONS_PER_USER.value(),
    monthlySuggestionBudget: MONTHLY_SUGGESTION_BUDGET.value(),
  };
}

const inEmulator = () => process.env.FUNCTIONS_EMULATOR === "true";

/** Production adapters by default; the emulator-only fakes are refused outside the emulator. */
function providers(): { geocoder: Geocoder; suggester: AddressSuggester; optimizer: TourOptimizer } {
  const mode = PROVIDER_MODE.value();
  if (mode === "emulator-fake") {
    if (!inEmulator()) throw errors.notConfigured("The routing provider", "PROVIDER_MODE=emulator-fake is only allowed in the Firebase Emulator Suite. Set PROVIDER_MODE=google.");
    return { geocoder: new FakeGeocoder(), suggester: new FakeSuggester(), optimizer: new FakeTourOptimizer() };
  }
  const projectId = process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT;
  if (!projectId) throw errors.notConfigured("The Google Cloud project", "Deploy the functions to a Firebase project.");
  return { geocoder: new GoogleGeocoder(), suggester: new GooglePlacesSuggester(), optimizer: new GoogleRouteOptimizer(projectId) };
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw errors.unauthenticated();
  return uid;
}

const callableOptions = { region: REGION, enforceAppCheck: ENFORCE_APP_CHECK, memory: "256MiB" as const, maxInstances: 20 };

async function guarded<T>(name: string, fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    const https = toHttpsError(e);
    // Log the error class only — never the request payload.
    logger.warn(`${name} failed`, { code: https.code, reason: (https.details as { reason?: string } | undefined)?.reason ?? (e instanceof AppError ? e.reason : "unknown") });
    throw https;
  }
}

export const resolveAddress = onCall({ ...callableOptions, timeoutSeconds: 30 }, (request) =>
  guarded("resolveAddress", async () => {
    const uid = requireUid(request);
    assertMayUsePaidFeatures(request.auth?.token);
    const { geocoder } = providers();
    return resolveAddressCore({ db: getFirestore(), geocoder, limits: limits(), now: () => new Date() }, uid, request.data);
  }),
);

export const suggestAddresses = onCall({ ...callableOptions, timeoutSeconds: 15 }, (request) =>
  guarded("suggestAddresses", async () => {
    const uid = requireUid(request);
    assertMayUsePaidFeatures(request.auth?.token);
    const { suggester } = providers();
    return suggestAddressesCore({ db: getFirestore(), suggester, limits: limits(), now: () => new Date() }, uid, request.data);
  }),
);

export const requestOptimization = onCall({ ...callableOptions, timeoutSeconds: 300, memory: "512MiB" }, (request) =>
  guarded("requestOptimization", async () => {
    const uid = requireUid(request);
    assertMayUsePaidFeatures(request.auth?.token);
    const { optimizer } = providers();
    return requestOptimizationCore(
      { db: getFirestore(), optimizer, limits: limits(), now: () => new Date(), allowSynthetic: optimizer.provider === "emulatorFake", retryDelaysMs: [1000, 3000] },
      uid,
      request.data,
    );
  }),
);

export const deleteAccount = onCall({ ...callableOptions, timeoutSeconds: 300 }, (request) =>
  guarded("deleteAccount", async () => {
    const uid = requireUid(request);
    const bucket = getStorage().bucket();
    return deleteAccountCore(
      { db: getFirestore(), auth: getAuth(), deleteStoragePrefix: (prefix) => bucket.deleteFiles({ prefix, force: true }), now: () => new Date() },
      uid,
      request.auth?.token.auth_time,
    );
  }),
);

export const purgeExpiredProviderContent = onSchedule({ schedule: "every day 03:30", timeZone: "America/Toronto", region: REGION }, async () => {
  const counts = await purgeCore(getFirestore(), new Date());
  logger.info("purged expired provider content", counts);
});
