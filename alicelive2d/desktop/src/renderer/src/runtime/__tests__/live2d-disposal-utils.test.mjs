import test from "node:test";
import assert from "node:assert/strict";

import { deleteGlProgramIfPresent, releaseIfPresent } from "../live2d-disposal-utils.ts";

test("releaseIfPresent ignores nullish resources", () => {
  assert.doesNotThrow(() => {
    releaseIfPresent(null);
    releaseIfPresent(undefined);
  });
});

test("releaseIfPresent calls release on initialized resources", () => {
  const calls = [];

  releaseIfPresent({
    release() {
      calls.push("released");
    },
  });

  assert.deepEqual(calls, ["released"]);
});

test("deleteGlProgramIfPresent skips missing gl/program values", () => {
  assert.doesNotThrow(() => {
    deleteGlProgramIfPresent(null, {});
    deleteGlProgramIfPresent({ deleteProgram() {} }, null);
  });
});

test("deleteGlProgramIfPresent deletes the provided program once", () => {
  const calls = [];
  const program = { id: "program" };

  deleteGlProgramIfPresent(
    {
      deleteProgram(target) {
        calls.push(target);
      },
    },
    program,
  );

  assert.deepEqual(calls, [program]);
});
