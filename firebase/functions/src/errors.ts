import { HttpsError, type FunctionsErrorCode } from "firebase-functions/v2/https";

/**
 * Errors returned to the app. Every error carries a machine-readable `reason` and a sentence the app
 * can show, plus suggested next actions. Messages never contain addresses or other user content.
 */
export class AppError extends Error {
  constructor(
    readonly code: FunctionsErrorCode,
    readonly reason: string,
    message: string,
    readonly suggestions: string[] = [],
    /** Whether the provider may have billed for the attempt (used to keep/release quota). */
    readonly possiblyBilled = false,
  ) {
    super(message);
  }

  toHttps(): HttpsError {
    return new HttpsError(this.code, this.message, { reason: this.reason, suggestions: this.suggestions });
  }
}

export const errors = {
  unauthenticated: () => new AppError("unauthenticated", "sign-in-required", "Sign in to use this feature."),
  invalidInput: (detail: string) => new AppError("invalid-argument", "invalid-input", `The request was not valid: ${detail}`),
  notFound: (what: string) => new AppError("not-found", "not-found", `${what} was not found.`),
  notConfigured: (what: string, suggestion: string) =>
    new AppError("failed-precondition", "not-configured", `${what} is not configured.`, [suggestion]),
  quotaExceeded: (what: string, resetHint: string) =>
    new AppError("resource-exhausted", "quota-exceeded", `${what} limit reached. ${resetHint}`, ["Try again later.", "Ask the app administrator to raise the limit if this keeps happening."]),
  providerUnavailable: (detail: string, possiblyBilled = false) =>
    new AppError("unavailable", "provider-unavailable", `The routing service is temporarily unavailable (${detail}). Your stops and current plan are unchanged.`, ["Try again in a minute."], possiblyBilled),
};

export function toHttpsError(e: unknown): HttpsError {
  if (e instanceof HttpsError) return e;
  if (e instanceof AppError) return e.toHttps();
  return new HttpsError("internal", "Something went wrong on the server. Nothing was changed.", { reason: "internal" });
}
