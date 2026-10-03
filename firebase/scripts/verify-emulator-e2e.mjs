// Verifies, server-side, what the emulator end-to-end UI test wrote (run with the emulators up):
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8180 node firebase/scripts/verify-emulator-e2e.mjs
import { createRequire } from "node:module";
const require = createRequire(new URL("../functions/package.json", import.meta.url));
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

process.env.FIRESTORE_EMULATOR_HOST ??= "127.0.0.1:8180";
initializeApp({ projectId: "demo-parcelpilot" });
const db = getFirestore();

const users = await db.collection("users").listDocuments();
let failures = 0;
const check = (ok, message) => { console.log(`${ok ? "PASS" : "FAIL"}  ${message}`); if (!ok) failures++; };

// Only routes built by the UI flow (pasted addresses) are checked; the SDK-level emulator tests
// (FirestoreBackendEmulatorTests) leave their own small routes behind for other users.
let checkedRoutes = 0;
for (const user of users) {
  const routes = await user.collection("routes").get();
  let userChecked = false;
  for (const route of routes.docs) {
    const [stops, packages, outcomes] = await Promise.all(["stops", "packages", "outcomes"].map((c) => route.ref.collection(c).get()));
    if (!packages.docs.some((p) => p.get("source") === "paste")) continue;
    checkedRoutes++;
    userChecked = true;
    const statuses = stops.docs.map((d) => d.get("addressStatus"));
    console.log(`user ${user.id.slice(0, 6)}… route "${route.get("name")}" rev ${route.get("inputRevision")}: ${stops.size} stops [${statuses.join(", ")}], ${packages.size} packages, ${outcomes.size} outcomes`);
    check(stops.size >= 4, "pasted stops were written through the Firestore SDK and accepted by the rules");
    check(statuses.includes("needsReview") || statuses.includes("unresolvable"), "address without a civic number was not accepted as a destination (E4)");
    check(!statuses.includes("verified"), "emulator test results are never stored as 'verified'");
    check(outcomes.docs.some((o) => o.get("kind") === "delivered" && !o.get("voidedAt")), "delivery outcome synced to the server");
    check(typeof route.get("appliedRequestID") === "string", "optimized order was applied to the route");
    check(route.get("inputRevision") >= 2, "adding stops incremented the route's input revision on the server");
    check(route.get("appliedRevision") === route.get("inputRevision"), "the applied plan was computed for the current input revision");
  }
  if (!userChecked) continue;
  const jobs = await user.collection("optimizationRequests").get();
  for (const job of jobs.docs) {
    console.log(`job ${job.id.slice(0, 8)}… status=${job.get("status")} provider=${job.get("provider")} visits=${job.get("proposal.visits")?.length ?? 0} unassigned=${job.get("proposal.unassigned")?.length ?? 0}`);
  }
  check(jobs.docs.some((j) => ["succeeded", "infeasible"].includes(j.get("status")) && j.get("provider") === "emulatorFake"), "callable optimization produced a job document with the labelled test provider");
}
check(checkedRoutes > 0, "the UI flow's route exists on the emulator");
process.exit(failures ? 1 : 0);
