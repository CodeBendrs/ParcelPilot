/**
 * `deleteAccount` core. Deletes everything the user owns: Firestore users/{uid} (recursively,
 * including routes, stops, packages, outcomes, photos metadata, jobs, usage counters), Cloud Storage
 * objects under users/{uid}/, and the Firebase Auth user. Idempotent: running it again after a partial
 * failure finishes the job.
 *
 * Sign in with Apple token revocation happens on the device before this call
 * (Auth.revokeToken(withAuthorizationCode:)), because it needs a fresh authorization code.
 */
import type { Auth } from "firebase-admin/auth";
import type { Firestore } from "firebase-admin/firestore";
import { AppError } from "./errors";

export interface AccountDeps {
  db: Firestore;
  auth: Auth;
  deleteStoragePrefix: (prefix: string) => Promise<void>;
  now: () => Date;
}

/** Requires a sign-in within the last 10 minutes so a stolen, long-lived session can't delete data. */
export const RECENT_SIGN_IN_SECONDS = 10 * 60;

export async function deleteAccount(deps: AccountDeps, uid: string, authTimeSeconds: number | undefined): Promise<{ deleted: true }> {
  const nowSeconds = Math.floor(deps.now().getTime() / 1000);
  if (!authTimeSeconds || nowSeconds - authTimeSeconds > RECENT_SIGN_IN_SECONDS) {
    throw new AppError("failed-precondition", "recent-sign-in-required", "For your security, sign in again before deleting your account.", ["Sign in again, then delete the account."]);
  }
  await deps.db.recursiveDelete(deps.db.doc(`users/${uid}`));
  await deps.deleteStoragePrefix(`users/${uid}/`);
  try {
    await deps.auth.deleteUser(uid);
  } catch (e) {
    if ((e as { code?: string }).code !== "auth/user-not-found") throw e;
  }
  return { deleted: true };
}
