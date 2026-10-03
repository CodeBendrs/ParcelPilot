import { AppError } from "./errors";

/** The parts of a Firebase ID token the paid-feature check reads. */
export interface PaidFeatureToken {
  email_verified?: boolean;
  firebase?: { sign_in_provider?: string };
}

/**
 * Address checks and optimization call paid Google APIs. Email/password accounts must verify their
 * address first, so throwaway sign-ups can't use up the project's monthly allowance. Google and Apple
 * accounts are verified by their provider.
 */
export function assertMayUsePaidFeatures(token: PaidFeatureToken | undefined): void {
  if (token?.firebase?.sign_in_provider === "password" && token.email_verified !== true) {
    throw new AppError(
      "failed-precondition",
      "email-not-verified",
      "Verify your email address to check addresses and plan routes. Open the link we sent you, then try again.",
      ["Use the banner at the top of the app to resend the link or refresh after verifying."],
    );
  }
}
