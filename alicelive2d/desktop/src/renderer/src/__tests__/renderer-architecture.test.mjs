import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rendererRoot = path.resolve(__dirname, "..");
const appSource = readFileSync(path.join(rendererRoot, "App.tsx"), "utf8");
const mainSource = readFileSync(path.join(rendererRoot, "main.tsx"), "utf8");
const rootShellSource = readFileSync(
  path.join(rendererRoot, "app/shell/root-shell.tsx"),
  "utf8",
);

function collectLegacyModuleFiles(directory, relativeDirectory = "") {
  const findings = [];

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name);
    const relativePath = path.join(relativeDirectory, entry.name);

    if (entry.isDirectory()) {
      findings.push(...collectLegacyModuleFiles(absolutePath, relativePath));
      continue;
    }

    const isTestFile = relativePath.includes("__tests__")
      || relativePath.endsWith(".test.mjs");
    if (isTestFile) {
      continue;
    }

    if (
      relativePath.endsWith(".mjs")
      || relativePath.endsWith(".mjs.d.ts")
      || relativePath.endsWith("mjs-modules.d.ts")
    ) {
      findings.push(relativePath);
    }
  }

  return findings.sort();
}

test("App uses the new root shell wiring instead of the legacy provider tower", () => {
  assert.match(appSource, /@\/app\/root-app/);
  assert.doesNotMatch(appSource, /ChatHistoryProvider/);
  assert.doesNotMatch(appSource, /AiStateProvider/);
  assert.doesNotMatch(appSource, /SubtitleProvider/);
  assert.doesNotMatch(appSource, /GroupProvider/);
  assert.doesNotMatch(appSource, /BrowserProvider/);
  assert.doesNotMatch(appSource, /LunariaRuntimeProvider/);
  assert.doesNotMatch(appSource, /LunariaShell/);
});

test("main delegates renderer boot to app boot instead of inlining startup orchestration", () => {
  assert.match(mainSource, /@\/app\/boot\/start-renderer-app/);
  assert.doesNotMatch(mainSource, /createRoot\(/);
  assert.doesNotMatch(mainSource, /ensureBootOverlay/);
  assert.doesNotMatch(mainSource, /loadLive2DCore/);
});

test("legacy renderer hotspots are removed from the tree", () => {
  const removedPaths = [
    "features/lunaria-shell.tsx",
    "runtime/app-store.ts",
    "runtime/lunaria-runtime.tsx",
    "runtime/mjs-modules.d.ts",
    "services/websocket-handler.tsx",
    "context/websocket-context.tsx",
    "context/desktop-runtime-context.tsx",
  ];

  for (const relativePath of removedPaths) {
    assert.equal(
      existsSync(path.join(rendererRoot, relativePath)),
      false,
      `${relativePath} should be removed`,
    );
  }
});

test("root shell delegates chat rendering to the shared chat surface", () => {
  assert.match(rootShellSource, /@\/domains\/chat\/ui\/chat-message-list/);
  assert.match(rootShellSource, /CurrentSessionMessageList/);
  assert.doesNotMatch(rootShellSource, /function MessageList\(/);
});

test("renderer source no longer ships non-test .mjs modules or legacy declaration shims", () => {
  assert.deepEqual(collectLegacyModuleFiles(rendererRoot), []);
});
