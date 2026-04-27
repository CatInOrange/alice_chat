import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const appSource = readFileSync(resolve(currentDir, "../App.tsx"), "utf8");
const rootAppSource = readFileSync(resolve(currentDir, "../app/root-app.tsx"), "utf8");
const providersSource = readFileSync(
  resolve(currentDir, "../app/providers/app-providers.tsx"),
  "utf8",
);

test("App routes through the new root app and command provider without the legacy websocket handler", () => {
  assert.match(appSource, /@\/app\/root-app/);
  assert.match(rootAppSource, /AppProviders/);
  assert.match(providersSource, /RendererCommandProvider/);
  assert.doesNotMatch(providersSource, /WebSocketHandler/);
  assert.doesNotMatch(providersSource, /LunariaRuntimeProvider/);
});
