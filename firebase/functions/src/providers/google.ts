/**
 * Production adapters for Google Maps Platform web services, authenticated with the Cloud Function's
 * runtime service account (Application Default Credentials, OAuth scope cloud-platform). No API key
 * or service-account key file is used or shipped.
 *
 * Required setup (see docs/COST_AND_SETUP.md): enable the Route Optimization API, the Geocoding API
 * and Places API (New) (address suggestions) in the Firebase project's Google Cloud project, and grant
 * the functions' runtime service account `roles/routeoptimization.editor`. Service-account calls bill to the account's own project, so no
 * `X-Goog-User-Project` header is sent.
 */
import { GoogleAuth } from "google-auth-library";
import { AppError, errors } from "../errors";
import type { OptimizeToursRequest, OptimizeToursResponse } from "../optimization/googleTypes";
import type { AddressSuggester, AddressSuggestionOut, GeocodeCandidateOut, GeocodeQuery, Geocoder, SuggestQuery, TourOptimizer } from "./interfaces";

const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });

async function authorizedFetch(url: string, init: RequestInit & { timeoutMs: number }): Promise<Response> {
  let token: string | null | undefined;
  try {
    const client = await auth.getClient();
    token = (await client.getAccessToken()).token;
  } catch {
    throw errors.notConfigured("Server credentials for Google Maps Platform", "Run the functions with a service account (see docs/COST_AND_SETUP.md).");
  }
  if (!token) throw errors.notConfigured("Server credentials for Google Maps Platform", "Run the functions with a service account (see docs/COST_AND_SETUP.md).");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), init.timeoutMs);
  try {
    return await fetch(url, {
      ...init,
      signal: controller.signal,
      headers: { ...(init.headers ?? {}), Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
  } catch (e) {
    if ((e as Error).name === "AbortError") throw errors.providerUnavailable("timed out", true);
    throw errors.providerUnavailable("network error");
  } finally {
    clearTimeout(timer);
  }
}

/** Maps an HTTP error from Google to an AppError. 4xx validation errors are not billed. */
async function providerError(res: Response, api: string): Promise<AppError> {
  let status = "";
  try {
    const body = (await res.json()) as { error?: { status?: string } };
    status = body.error?.status ?? "";
  } catch { /* ignore */ }
  if (res.status === 401 || res.status === 403 || status === "PERMISSION_DENIED") {
    return errors.notConfigured(`${api} access`, `Enable ${api} and grant the functions service account access (docs/COST_AND_SETUP.md).`);
  }
  if (res.status === 429 || status === "RESOURCE_EXHAUSTED") return errors.quotaExceeded(`${api} provider quota`, "Google's per-minute or daily quota was reached.");
  if (res.status === 400 || status === "INVALID_ARGUMENT" || status === "FAILED_PRECONDITION") {
    return new AppError("failed-precondition", "provider-rejected", `${api} rejected the request. Check the stops' constraints; nothing was changed.`, ["Review time windows, pins and the break, then try again."]);
  }
  return errors.providerUnavailable(`${api} HTTP ${res.status}`, res.status === 504);
}

export class GoogleRouteOptimizer implements TourOptimizer {
  readonly provider = "google" as const;
  constructor(private readonly projectId: string) {}

  async optimizeTours(request: OptimizeToursRequest, timeoutMs: number): Promise<OptimizeToursResponse> {
    const url = `https://routeoptimization.googleapis.com/v1/projects/${encodeURIComponent(this.projectId)}:optimizeTours`;
    const res = await authorizedFetch(url, { method: "POST", body: JSON.stringify(request), timeoutMs });
    if (!res.ok) throw await providerError(res, "Route Optimization API");
    return (await res.json()) as OptimizeToursResponse;
  }
}

interface V4Component { longText?: string; shortText?: string; types?: string[] }
interface V4Result {
  placeId?: string;
  location?: { latitude: number; longitude: number };
  granularity?: string;
  formattedAddress?: string;
  types?: string[];
  addressComponents?: V4Component[];
}

const FIELD_MASK = ["placeId", "location", "granularity", "formattedAddress", "types", "addressComponents"];

export function mapV4Result(r: V4Result): GeocodeCandidateOut | null {
  if (!r.location) return null;
  const comp = (type: string, short = false) => {
    const c = (r.addressComponents ?? []).find((x) => x.types?.includes(type));
    return (short ? c?.shortText : c?.longText) ?? undefined;
  };
  const granularity = ({ ROOFTOP: "rooftop", RANGE_INTERPOLATED: "rangeInterpolated", GEOMETRIC_CENTER: "geometricCenter", APPROXIMATE: "approximate" } as Record<string, GeocodeCandidateOut["granularity"]>)[r.granularity ?? ""] ?? "unknown";
  return {
    placeID: r.placeId,
    formattedAddress: r.formattedAddress ?? "",
    location: { latitude: r.location.latitude, longitude: r.location.longitude },
    granularity,
    types: r.types ?? [],
    streetNumber: comp("street_number"),
    route: comp("route"),
    subpremise: comp("subpremise"),
    locality: comp("locality") ?? comp("postal_town") ?? comp("sublocality"),
    provinceCode: comp("administrative_area_level_1", true),
    postalCode: comp("postal_code"),
    countryCode: comp("country", true),
    provider: "google",
  };
}

interface PlacePrediction {
  placeId?: string;
  text?: { text?: string };
  structuredFormat?: { mainText?: { text?: string }; secondaryText?: { text?: string } };
}

export function mapPlacePrediction(p: PlacePrediction | undefined): AddressSuggestionOut | null {
  if (!p?.placeId) return null;
  const primaryText = p.structuredFormat?.mainText?.text ?? p.text?.text;
  if (!primaryText) return null;
  return { placeId: p.placeId, primaryText, secondaryText: p.structuredFormat?.secondaryText?.text, provider: "google" };
}

/** Address types only, so businesses and landmarks don't crowd out delivery addresses. */
const SUGGESTION_TYPES = ["street_address", "premise", "subpremise"];
const BIAS_RADIUS_M = 50_000;

export function buildAutocompleteBody(q: SuggestQuery): Record<string, unknown> {
  const body: Record<string, unknown> = {
    input: q.input,
    sessionToken: q.sessionToken,
    includedRegionCodes: ["ca"],
    includedPrimaryTypes: SUGGESTION_TYPES,
    regionCode: "ca",
  };
  if (q.languageCode) body.languageCode = q.languageCode;
  if (q.near) body.locationBias = { circle: { center: q.near, radius: BIAS_RADIUS_M } };
  return body;
}

/** Places API (New) Autocomplete. The chosen place is then resolved with the Geocoding API by place ID. */
export class GooglePlacesSuggester implements AddressSuggester {
  readonly provider = "google" as const;

  async suggest(query: SuggestQuery): Promise<AddressSuggestionOut[]> {
    const res = await authorizedFetch("https://places.googleapis.com/v1/places:autocomplete", {
      method: "POST",
      headers: { "X-Goog-FieldMask": "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text,suggestions.placePrediction.structuredFormat" },
      body: JSON.stringify(buildAutocompleteBody(query)),
      timeoutMs: 5_000,
    });
    if (!res.ok) throw await providerError(res, "Places API");
    const body = (await res.json()) as { suggestions?: Array<{ placePrediction?: PlacePrediction }> };
    return (body.suggestions ?? []).map((s) => mapPlacePrediction(s.placePrediction)).filter((x): x is AddressSuggestionOut => x !== null).slice(0, 5);
  }
}

export class GoogleGeocoder implements Geocoder {
  readonly provider = "google" as const;

  async geocode(query: GeocodeQuery): Promise<GeocodeCandidateOut[]> {
    let url: string;
    if (query.placeId) {
      url = `https://geocode.googleapis.com/v4/geocode/places/${encodeURIComponent(query.placeId)}`;
    } else {
      const params = new URLSearchParams({ regionCode: "CA" });
      if (query.languageCode) params.set("languageCode", query.languageCode);
      if (query.address) {
        params.set("address.regionCode", "CA");
        for (const line of query.address.addressLines) params.append("address.addressLines", line);
        if (query.address.locality) params.set("address.locality", query.address.locality);
        if (query.address.province) params.set("address.administrativeArea", query.address.province);
        if (query.address.postalCode) params.set("address.postalCode", query.address.postalCode);
      } else {
        params.set("addressQuery", query.query!);
      }
      url = `https://geocode.googleapis.com/v4/geocode/address?${params.toString()}`;
    }
    const mask = query.placeId ? FIELD_MASK.join(",") : FIELD_MASK.map((f) => `results.${f}`).join(",");
    const res = await authorizedFetch(url, { method: "GET", headers: { "X-Goog-FieldMask": mask }, timeoutMs: 10_000 });
    if (res.status === 404) return [];
    if (!res.ok) throw await providerError(res, "Geocoding API");
    const body = (await res.json()) as { results?: V4Result[] } & V4Result;
    const results = query.placeId ? [body] : body.results ?? [];
    return results.map(mapV4Result).filter((x): x is GeocodeCandidateOut => x !== null).slice(0, 5);
  }
}
