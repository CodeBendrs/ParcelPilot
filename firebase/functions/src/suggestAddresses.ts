/**
 * `suggestAddresses` core: address autocomplete while the driver types. Returns place IDs and display
 * text only — no coordinates. Picking a suggestion resolves it through `resolveAddress` (placeId),
 * which applies the geocoding limits. Inputs and results are never logged.
 */
import type { Firestore } from "firebase-admin/firestore";
import { AppError, errors } from "./errors";
import { release, reserveSuggestion, type Limits } from "./quota";
import type { AddressSuggester, AddressSuggestionOut } from "./providers/interfaces";
import { parseInput, SuggestAddressesInput } from "./validation";

export interface SuggestDeps {
  db: Firestore;
  suggester: AddressSuggester;
  limits: Limits;
  now: () => Date;
}

export interface SuggestResult {
  provider: "google" | "emulatorFake";
  suggestions: AddressSuggestionOut[];
}

export async function suggestAddresses(deps: SuggestDeps, uid: string, raw: unknown): Promise<SuggestResult> {
  let input: SuggestAddressesInput;
  try {
    input = parseInput(SuggestAddressesInput, raw);
  } catch (e) {
    throw errors.invalidInput((e as Error).message);
  }
  const reservation = await reserveSuggestion(deps.db, uid, deps.limits, deps.now());
  try {
    return { provider: deps.suggester.provider, suggestions: await deps.suggester.suggest(input) };
  } catch (e) {
    const err = e instanceof AppError ? e : errors.providerUnavailable("suggester error");
    if (!err.possiblyBilled) await release(deps.db, reservation).catch(() => undefined);
    throw err;
  }
}
