/**
 * Route-local wall-clock time → UTC instant. Mirrors ParcelPilotKit `WallClock` exactly and is tested
 * against the shared fixture fixtures/shared/timezone-cases.json.
 *
 * Policy: minutes are wall-clock minutes after local midnight of the service date (≥ 1440 = next day).
 * Nonexistent local times (spring-forward gap) shift forward by the gap; ambiguous local times
 * (fall-back overlap) resolve to the earlier instant.
 *
 * Offsets come from the runtime's IANA database via Luxon/Intl. Databases differ between versions
 * (e.g. Alberta's 2026 move to permanent UTC−6), so the server treats the device's computed instants
 * as authoritative and uses this module only for plausibility checks.
 */
import { IANAZone } from "luxon";

export type Resolution = "exact" | "shiftedForwardFromGap" | "earlierOfAmbiguous";

const DAY_MS = 86_400_000;

function offsetMinutes(zone: IANAZone, epochMs: number): number {
  return zone.offset(epochMs);
}

export function parseServiceDate(iso: string): { year: number; month: number; day: number } | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return null;
  const [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const d = new Date(Date.UTC(year, month - 1, day));
  if (d.getUTCFullYear() !== year || d.getUTCMonth() !== month - 1 || d.getUTCDate() !== day) return null;
  return { year, month, day };
}

export function wallClockToInstant(serviceDate: string, minute: number, timeZone: string): { date: Date; resolution: Resolution } {
  const date = parseServiceDate(serviceDate);
  if (!date) throw new Error("invalid service date");
  if (!Number.isInteger(minute) || minute < 0) throw new Error("invalid minute");
  const zone = IANAZone.create(timeZone);
  if (!zone.isValid) throw new Error("invalid time zone");

  const dayOffset = Math.floor(minute / 1440);
  const minuteOfDay = minute % 1440;
  const localAsUTC = Date.UTC(date.year, date.month - 1, date.day + dayOffset, Math.floor(minuteOfDay / 60), minuteOfDay % 60);

  const before = offsetMinutes(zone, localAsUTC - DAY_MS);
  const after = offsetMinutes(zone, localAsUTC + DAY_MS);
  const valid: number[] = [];
  for (const offset of new Set([before, after])) {
    const candidate = localAsUTC - offset * 60_000;
    if (offsetMinutes(zone, candidate) === offset) valid.push(candidate);
  }
  if (valid.length === 1) return { date: new Date(valid[0]), resolution: "exact" };
  if (valid.length > 1) return { date: new Date(Math.min(...valid)), resolution: "earlierOfAmbiguous" };
  return { date: new Date(localAsUTC - before * 60_000), resolution: "shiftedForwardFromGap" };
}

export function rfc3339(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Seconds, as the Route Optimization API's Duration string. */
export function duration(seconds: number): string {
  return `${Math.max(0, Math.round(seconds))}s`;
}

/** Parses a protobuf Duration string such as "123s" or "1.500s". */
export function parseDuration(value: string | undefined | null): number {
  if (!value) return 0;
  const m = /^(-?\d+(?:\.\d+)?)s$/.exec(value);
  return m ? Number(m[1]) : 0;
}
