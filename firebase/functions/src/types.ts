/**
 * Shapes of documents written by the iOS app (Swift Codable via the Firestore encoder) and by these
 * functions. Field names match the Swift property names exactly. See docs/DATA_MODEL.md.
 */
import type { Timestamp } from "firebase-admin/firestore";

export type Province = "NL" | "PE" | "NS" | "NB" | "QC" | "ON" | "MB" | "SK" | "AB" | "BC" | "YT" | "NT" | "NU";

export interface PostalAddressDoc {
  recipientName?: string;
  unit?: string;
  unitDesignator?: string;
  civicNumber?: string;
  streetName?: string;
  deliveryInstallation?: string;
  municipality?: string;
  province?: Province;
  postalCode?: string;
  country?: string;
  additionalLines?: string[];
}

export type PointSource = "deviceLocation" | "driverPin" | "providerGeocode" | "demoSynthetic" | "emulatorFake";

export interface LocatedPointDoc {
  point: { latitude: number; longitude: number };
  source: PointSource;
  expiresAt?: Timestamp;
}

export interface RoutePlaceDoc {
  label: string;
  address?: PostalAddressDoc;
  located?: LocatedPointDoc;
  placeID?: string;
}

export interface RouteDoc {
  id: string;
  schemaVersion: number;
  name: string;
  status: "planning" | "active" | "completed" | "archived";
  serviceDate: string;
  timeZoneID: string;
  departureMinute: number;
  latestArrivalMinute?: number;
  start?: RoutePlaceDoc;
  end?: RoutePlaceDoc;
  returnToStart: boolean;
  defaultServiceSeconds: number;
  breakRule?: { earliestStartMinute: number; latestStartMinute: number; durationSeconds: number };
  objective: "balanced" | "fastest";
  considerTraffic: boolean;
  inputRevision: number;
}

export type AddressStatus = "verified" | "driverConfirmed" | "pendingVerification" | "needsReview" | "unresolvable" | "demoSynthetic";

export interface StopDoc {
  id: string;
  address: PostalAddressDoc;
  destinationKey: string;
  addressStatus: AddressStatus;
  resolution?: {
    provider?: "google" | "demo" | "emulatorFake";
    placeID?: string;
    located?: LocatedPointDoc;
    match: string;
    resolvedAt: Timestamp;
  };
  sequence: number;
  pin: "none" | "first" | "last";
  timeWindow?: { kind: "hard" | "softDeadline"; startMinute?: number; endMinute: number };
  serviceSeconds?: number;
  createdAt: Timestamp;
}

export interface PackageDoc {
  id: string;
  stopID: string;
  createdAt: Timestamp;
}

/** Delivery work is projected from packages; only pickup/checklist definitions are stored. */
export interface LocationTaskDoc {
  id: string;
  schemaVersion: number;
  stopID: string;
  /** Raw value so future required work can be reported rather than silently discarded. */
  kind: string;
  required: boolean;
  title: string;
  instructions: string;
  orderRank: number;
  /** Association only; outcomes still target this standalone task, not the package delivery. */
  packageID?: string;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

export type OutcomeKind = "delivered" | "completed" | "failed" | "skipped" | "requeued" | "excluded";

export interface OutcomeDoc {
  id: string;
  schemaVersion?: number;
  /** Legacy rows have packageID; schema 2 also names the generalized task. */
  packageID?: string;
  taskID?: string;
  stopID: string;
  kind: OutcomeKind;
  reason?: string;
  note?: string;
  recordedAt: Timestamp;
  voidedAt?: Timestamp;
  photoIDs?: string[];
}

/** Issue with a machine code, a plain explanation and suggested driver actions. */
export interface PlanIssue {
  code: string;
  message: string;
  suggestions: string[];
}

export type OriginInput =
  | { kind: "routeStart" }
  | { kind: "currentLocation"; latitude: number; longitude: number }
  | { kind: "stop"; stopId: string };

export interface PlannedVisitOut {
  stopId: string;
  arrival: Timestamp;
  start: Timestamp;
  departure: Timestamp;
  lateBySeconds?: number;
}

export interface PlanMetricsOut {
  routeStart: Timestamp;
  routeEnd: Timestamp;
  travelSeconds: number;
  travelMeters: number;
  serviceSeconds: number;
  waitSeconds: number;
  breakSeconds: number;
}

export type ExcludedReason = "completed" | "addressNotVerified" | "noUsableLocation" | "noPendingPackages" | "onlySkippedPackages" | "unsupportedTasks";

export interface ProposalOut {
  requestId: string;
  routeId: string;
  inputRevision: number;
  provider: "google" | "emulatorFake";
  status: "feasible" | "infeasible";
  calculatedAt: Timestamp;
  expiresAt: Timestamp;
  trafficConsidered: boolean;
  origin: OriginInput;
  fixedNextStopId: string | null;
  visits: PlannedVisitOut[];
  unassigned: Array<{ stopId: string } & PlanIssue>;
  excluded: Array<{ stopId: string; reason: ExcludedReason }>;
  breaks: Array<{ start: Timestamp; durationSeconds: number }>;
  metrics: PlanMetricsOut | null;
  baseline: PlanMetricsOut | null;
  baselineNote: string | null;
  /** One encoded polyline per segment (Google content — display on a Google map only). */
  polylines: string[];
  completedStopIdsAtRequest: string[];
  warnings: string[];
}

export type JobStatus = "queued" | "running" | "succeeded" | "infeasible" | "failed" | "stale" | "cancelled";
