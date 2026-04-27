import test from "node:test";
import assert from "node:assert/strict";

import { resolveStorageValue } from "../local-storage-utils.ts";

test("resolveStorageValue applies functional updates against the current stored value", () => {
  const result = resolveStorageValue(
    { count: 2 },
    (current) => ({ count: current.count + 1 }),
  );

  assert.deepEqual(result.valueToStore, { count: 3 });
  assert.deepEqual(result.filteredValue, { count: 3 });
});

test("resolveStorageValue applies the optional filter to the persisted value only", () => {
  const result = resolveStorageValue(
    { url: "/full/model.json", name: "Hiyori" },
    { url: "/full/model.json", name: "Hiyori" },
    (value) => ({ ...value, url: "" }),
  );

  assert.deepEqual(result.valueToStore, { url: "/full/model.json", name: "Hiyori" });
  assert.deepEqual(result.filteredValue, { url: "", name: "Hiyori" });
});
