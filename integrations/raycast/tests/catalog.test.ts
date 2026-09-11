import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadCatalog, parseCatalog, submitRequest } from "../src/catalog";

const useCase = { id: randomUUID(), name: "日本語へ翻訳", readReplies: false, confirmBeforeSending: false };
const catalog = JSON.stringify({ version: 1, applicationPath: "/Applications/Talk to Webex bot.app", useCases: [useCase] });

test("parses all entries, including ones with no hotkey, and rejects incompatible or duplicate data", () => {
  assert.deepEqual(parseCatalog(catalog), [{ ...useCase, hotkey: undefined }]);
  assert.deepEqual(parseCatalog('{"version":1,"useCases":[]}'), []);
  for (const raw of ["null", '{"version":2,"useCases":[]}', JSON.stringify({ version: 1, useCases: [useCase, useCase] }),
    JSON.stringify({ version: 1, useCases: [{ ...useCase, id: "../file" }] })]) assert.throws(() => parseCatalog(raw));
});

test("reads fresh saved catalog on each invocation and reports missing setup", async () => {
  const root = await mkdtemp(join(tmpdir(), "talk-raycast-"));
  try {
    await assert.rejects(loadCatalog(root), /一度起動/);
    await writeFile(join(root, "screen-use-cases.json"), catalog);
    assert.equal((await loadCatalog(root))[0].name, useCase.name);
    await writeFile(join(root, "screen-use-cases.json"), '{"version":1,"useCases":[]}');
    assert.equal((await loadCatalog(root)).length, 0);
  } finally { await rm(root, { recursive: true }); }
});

test("submits only an ID and target, uses a private one-use file, handles acknowledgment, and removes files", async () => {
  const root = await mkdtemp(join(tmpdir(), "talk-raycast-"));
  try {
    await writeFile(join(root, "screen-use-cases.json"), catalog);
    let dispatched = 0;
    const message = await submitRequest(useCase, "com.apple.TextEdit", root, async (raw, appPath) => {
      assert.equal(appPath, "/Applications/Talk to Webex bot.app");
      dispatched++;
      const url = new URL(raw), id = url.searchParams.get("request");
      assert.equal(url.hostname, "run");
      assert.ok(id && id !== useCase.id);
      const path = join(root, "raycast-requests", `${id}.json`);
      const request = JSON.parse(await readFile(path, "utf8"));
      assert.equal(request.useCaseID, useCase.id);
      assert.equal(request.expectedBundleID, "com.apple.TextEdit");
      assert.deepEqual(Object.keys(request).sort(), ["createdAt", "expectedBundleID", "useCaseID"]);
      assert.ok(Math.abs(Date.now() / 1000 - request.createdAt) < 5);
      assert.equal((await stat(path)).mode & 0o777, 0o600);
      await writeFile(join(root, "raycast-requests", `${id}.response.json`), JSON.stringify({ accepted: true, message: "started" }));
    });
    assert.equal(dispatched, 1);
    assert.equal(message, "started");
    assert.deepEqual(await readdir(join(root, "raycast-requests")), []);
  } finally { await rm(root, { recursive: true }); }
});

test("refuses removed entries, invalid targets, and application rejection without retries", async () => {
  const root = await mkdtemp(join(tmpdir(), "talk-raycast-"));
  try {
    await writeFile(join(root, "screen-use-cases.json"), catalog);
    for (const target of ["", "com.raycast.macos", "org.localvoicerelay.app"]) {
      await assert.rejects(submitRequest(useCase, target, root, async () => assert.fail("Must not dispatch")));
    }
    let dispatched = 0;
    await assert.rejects(submitRequest(useCase, "com.apple.TextEdit", root, async (raw) => {
      dispatched++;
      const id = new URL(raw).searchParams.get("request");
      await writeFile(join(root, "raycast-requests", `${id}.response.json`), JSON.stringify({ accepted: false, message: "busy" }));
    }), /busy/);
    assert.equal(dispatched, 1);
    assert.deepEqual(await readdir(join(root, "raycast-requests")), []);
    await writeFile(join(root, "screen-use-cases.json"), '{"version":1,"useCases":[]}');
    await assert.rejects(submitRequest(useCase, "com.apple.TextEdit", root, async () => assert.fail("Must not dispatch")), /削除/);
  } finally { await rm(root, { recursive: true }); }
});
