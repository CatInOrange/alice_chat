import test from "node:test";
import assert from "node:assert/strict";
import {
  normalizeSupportedLanguage,
  resolveBackendUrlCommit,
  resolveProviderFieldLabel,
  resolveProviderFieldPlaceholder,
} from "../settings-panel-utils.ts";

test("normalizeSupportedLanguage keeps supported languages and normalizes region variants", () => {
  assert.equal(normalizeSupportedLanguage("en"), "en");
  assert.equal(normalizeSupportedLanguage("en-US"), "en");
  assert.equal(normalizeSupportedLanguage("zh"), "zh");
  assert.equal(normalizeSupportedLanguage("zh-CN"), "zh");
});

test("normalizeSupportedLanguage falls back to english for unsupported input", () => {
  assert.equal(normalizeSupportedLanguage("fr"), "en");
  assert.equal(normalizeSupportedLanguage(""), "en");
  assert.equal(normalizeSupportedLanguage(undefined), "en");
});

test("resolveProviderFieldLabel prefers backend label and falls back to a readable field key", () => {
  assert.equal(resolveProviderFieldLabel({ label: "API Key", key: "apiKey" }), "API Key");
  assert.equal(resolveProviderFieldLabel({ key: "baseUrl" }), "Base Url");
  assert.equal(resolveProviderFieldLabel({ key: "bridge_url" }), "Bridge Url");
});

test("resolveProviderFieldPlaceholder prefers explicit placeholder and otherwise uses the resolved label", () => {
  assert.equal(
    resolveProviderFieldPlaceholder({ placeholder: "sk-...", label: "API Key", key: "apiKey" }),
    "sk-...",
  );
  assert.equal(
    resolveProviderFieldPlaceholder({ label: "Endpoint", key: "baseUrl" }),
    "Endpoint",
  );
  assert.equal(
    resolveProviderFieldPlaceholder({ key: "baseUrl" }),
    "Base Url",
  );
});

test("resolveBackendUrlCommit ignores blank input when the current URL already matches the default backend", () => {
  assert.deepEqual(
    resolveBackendUrlCommit({
      draftUrl: "   ",
      currentUrl: "http://127.0.0.1:18080",
    }),
    {
      nextUrl: "http://127.0.0.1:18080",
      shouldStore: false,
    },
  );
});

test("resolveBackendUrlCommit canonicalizes equivalent backend URLs without forcing a reconnecting change", () => {
  assert.deepEqual(
    resolveBackendUrlCommit({
      draftUrl: "lunaria.example.com/api/",
      currentUrl: "http://lunaria.example.com/api",
    }),
    {
      nextUrl: "http://lunaria.example.com/api",
      shouldStore: false,
    },
  );
});

test("resolveBackendUrlCommit applies a new backend target after trimming and normalization", () => {
  assert.deepEqual(
    resolveBackendUrlCommit({
      draftUrl: "  https://next.example.com/base/  ",
      currentUrl: "http://127.0.0.1:18080",
    }),
    {
      nextUrl: "https://next.example.com/base",
      shouldStore: true,
    },
  );
});
