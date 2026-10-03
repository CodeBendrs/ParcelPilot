import type { OptimizeToursRequest, OptimizeToursResponse } from "../optimization/googleTypes";

export interface GeocodeQuery {
  address?: { addressLines: string[]; locality?: string; province?: string; postalCode?: string };
  query?: string;
  placeId?: string;
  languageCode?: "en" | "fr";
}

/** Mirrors ParcelPilotKit `GeocodeCandidate` (field names match the Swift Codable keys). */
export interface GeocodeCandidateOut {
  placeID?: string;
  formattedAddress: string;
  location: { latitude: number; longitude: number };
  granularity: "rooftop" | "rangeInterpolated" | "geometricCenter" | "approximate" | "unknown";
  types: string[];
  streetNumber?: string;
  route?: string;
  subpremise?: string;
  locality?: string;
  provinceCode?: string;
  postalCode?: string;
  countryCode?: string;
  provider: "google" | "emulatorFake";
}

export interface Geocoder {
  readonly provider: "google" | "emulatorFake";
  geocode(query: GeocodeQuery): Promise<GeocodeCandidateOut[]>;
}

/** One autocomplete suggestion. Picking it resolves the place ID through `resolveAddress`. */
export interface AddressSuggestionOut {
  placeId: string;
  primaryText: string;
  secondaryText?: string;
  provider: "google" | "emulatorFake";
}

export interface SuggestQuery {
  input: string;
  sessionToken: string;
  languageCode?: "en" | "fr";
  near?: { latitude: number; longitude: number };
}

export interface AddressSuggester {
  readonly provider: "google" | "emulatorFake";
  suggest(query: SuggestQuery): Promise<AddressSuggestionOut[]>;
}

export interface TourOptimizer {
  readonly provider: "google" | "emulatorFake";
  optimizeTours(request: OptimizeToursRequest, timeoutMs: number): Promise<OptimizeToursResponse>;
}
