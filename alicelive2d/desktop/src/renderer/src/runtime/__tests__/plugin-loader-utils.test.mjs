import test from "node:test";
import assert from "node:assert/strict";

import { rebuildPluginCatalogState } from "../plugin-loader-utils.ts";

test("rebuildPluginCatalogState clears loaded plugins and indexes capabilities from fresh items", () => {
  const loadedPlugins = new Map([
    ["builtin.echo", { id: "builtin.echo" }],
  ]);

  const { pluginItems, capabilityIndex } = rebuildPluginCatalogState([
    {
      id: "builtin.echo",
      manifest: {
        id: "builtin.echo",
        capabilities: [
          { name: "echo.say" },
        ],
      },
    },
    {
      id: "builtin.screenshot",
      manifest: {
        id: "builtin.screenshot",
        capabilities: [
          { name: "screen.capture" },
        ],
      },
    },
  ], loadedPlugins);

  assert.equal(loadedPlugins.size, 0);
  assert.equal(pluginItems.size, 2);
  assert.deepEqual(capabilityIndex.get("echo.say"), {
    pluginId: "builtin.echo",
    capability: { name: "echo.say" },
  });
  assert.deepEqual(capabilityIndex.get("screen.capture"), {
    pluginId: "builtin.screenshot",
    capability: { name: "screen.capture" },
  });
});
