import { assertFails, assertSucceeds, initializeTestEnvironment, type RulesTestEnvironment } from "@firebase/rules-unit-testing";
import { deleteObject, getBytes, ref, uploadBytes } from "firebase/storage";
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, it } from "vitest";

let env: RulesTestEnvironment;

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-parcelpilot",
    storage: { rules: readFileSync("storage.rules", "utf8") },
  });
});
afterAll(async () => env.cleanup());

const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0xff, 0xd9]);
const path = (uid: string, name = "ph1.jpg") => `users/${uid}/routes/r1/pod/${name}`;

describe("proof-of-delivery photo storage", () => {
  it("lets the owner upload, read and delete a JPEG", async () => {
    const storage = env.authenticatedContext("alice").storage();
    await assertSucceeds(uploadBytes(ref(storage, path("alice")), jpeg, { contentType: "image/jpeg" }));
    await assertSucceeds(getBytes(ref(storage, path("alice"))));
    await assertSucceeds(deleteObject(ref(storage, path("alice"))));
  });

  it("denies other users and signed-out clients", async () => {
    const alice = env.authenticatedContext("alice").storage();
    await assertSucceeds(uploadBytes(ref(alice, path("alice", "ph2.jpg")), jpeg, { contentType: "image/jpeg" }));
    const bob = env.authenticatedContext("bob").storage();
    await assertFails(getBytes(ref(bob, path("alice", "ph2.jpg"))));
    await assertFails(uploadBytes(ref(bob, path("alice", "ph3.jpg")), jpeg, { contentType: "image/jpeg" }));
    await assertFails(deleteObject(ref(bob, path("alice", "ph2.jpg"))));
    const anon = env.unauthenticatedContext().storage();
    await assertFails(getBytes(ref(anon, path("alice", "ph2.jpg"))));
  });

  it("rejects non-JPEG content, oversize files, overwrites and other paths", async () => {
    const storage = env.authenticatedContext("alice").storage();
    await assertFails(uploadBytes(ref(storage, path("alice", "ph4.jpg")), jpeg, { contentType: "image/png" }));
    await assertFails(uploadBytes(ref(storage, path("alice", "ph5.jpg")), new Uint8Array(5 * 1024 * 1024 + 1), { contentType: "image/jpeg" }));
    await assertSucceeds(uploadBytes(ref(storage, path("alice", "ph6.jpg")), jpeg, { contentType: "image/jpeg" }));
    await assertFails(uploadBytes(ref(storage, path("alice", "ph6.jpg")), jpeg, { contentType: "image/jpeg" }));
    await assertFails(uploadBytes(ref(storage, "users/alice/labels/label.jpg"), jpeg, { contentType: "image/jpeg" }));
    await assertFails(uploadBytes(ref(storage, path("alice", "../../x.jpg")), jpeg, { contentType: "image/jpeg" }));
  });
});
