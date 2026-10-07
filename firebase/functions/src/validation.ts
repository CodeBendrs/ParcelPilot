import { z } from "zod";

const id = z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/, "invalid id");
const isoInstant = z.string().max(40).refine((s) => !Number.isNaN(Date.parse(s)), "invalid timestamp");

export const ResolveAddressInput = z
  .object({
    address: z
      .object({
        addressLines: z.array(z.string().max(160)).min(1).max(4),
        locality: z.string().max(80).optional(),
        province: z.string().max(40).optional(),
        postalCode: z.string().max(10).optional(),
      })
      .strict()
      .optional(),
    query: z.string().min(3).max(300).optional(),
    placeId: z.string().min(3).max(300).regex(/^[A-Za-z0-9_-]+$/).optional(),
    languageCode: z.enum(["en", "fr"]).optional(),
  })
  .strict()
  .refine((v) => [v.address, v.query, v.placeId].filter((x) => x !== undefined).length === 1, "provide exactly one of address, query or placeId");
export type ResolveAddressInput = z.infer<typeof ResolveAddressInput>;

export const SuggestAddressesInput = z
  .object({
    input: z.string().trim().min(3).max(200),
    sessionToken: z.string().min(8).max(64).regex(/^[A-Za-z0-9_-]+$/),
    languageCode: z.enum(["en", "fr"]).optional(),
    near: z.object({ latitude: z.number().min(41).max(84), longitude: z.number().min(-142).max(-52) }).strict().optional(),
  })
  .strict();
export type SuggestAddressesInput = z.infer<typeof SuggestAddressesInput>;

const origin = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("routeStart") }).strict(),
  z.object({ kind: z.literal("currentLocation"), latitude: z.number().min(41).max(84), longitude: z.number().min(-142).max(-52) }).strict(),
  z.object({ kind: z.literal("stop"), stopId: id }).strict(),
]);

/**
 * The device computes UTC instants for every wall-clock time (its time-zone database is the one the
 * driver sees); the server checks them for plausibility against its own conversion.
 */
const timeline = z
  .object({
    departure: isoInstant,
    latestArrival: isoInstant.optional(),
    windows: z.record(id, z.object({ start: isoInstant.optional(), end: isoInstant }).strict()),
    breakWindow: z.object({ earliest: isoInstant, latest: isoInstant }).strict().optional(),
    tzdataVersion: z.string().max(20).optional(),
  })
  .strict();

export const RequestOptimizationInput = z
  .object({
    requestId: id,
    routeId: id,
    inputRevision: z.number().int().min(1),
    origin,
    fixedNextStopId: id.optional(),
    computeBaseline: z.boolean().default(false),
    considerTraffic: z.boolean().default(true),
    departNow: z.boolean().default(false),
    timeline,
  })
  .strict();
export type RequestOptimizationInput = z.infer<typeof RequestOptimizationInput>;

export function parseInput<T extends z.ZodTypeAny>(schema: T, data: unknown): z.infer<T> {
  const result = schema.safeParse(data);
  if (!result.success) {
    const first = result.error.issues[0];
    const where = first?.path?.length ? first.path.join(".") : "request";
    throw Object.assign(new Error(`${where}: ${first?.message ?? "invalid"}`), { validation: true });
  }
  return result.data;
}
