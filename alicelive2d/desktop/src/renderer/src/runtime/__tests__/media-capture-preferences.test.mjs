import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_IMAGE_COMPRESSION_QUALITY,
  DEFAULT_IMAGE_MAX_WIDTH,
  parseMediaCaptureNumber,
} from "../media-capture-preferences.ts";

test("parseMediaCaptureNumber keeps valid numeric values inside bounds", () => {
  assert.equal(
    parseMediaCaptureNumber("0.8", DEFAULT_IMAGE_COMPRESSION_QUALITY, { min: 0.1, max: 1 }),
    0.8,
  );
  assert.equal(
    parseMediaCaptureNumber("2048", DEFAULT_IMAGE_MAX_WIDTH, { min: 0 }),
    2048,
  );
});

test("parseMediaCaptureNumber falls back when values are invalid or outside bounds", () => {
  assert.equal(
    parseMediaCaptureNumber("abc", DEFAULT_IMAGE_COMPRESSION_QUALITY, { min: 0.1, max: 1 }),
    DEFAULT_IMAGE_COMPRESSION_QUALITY,
  );
  assert.equal(
    parseMediaCaptureNumber("0.01", DEFAULT_IMAGE_COMPRESSION_QUALITY, { min: 0.1, max: 1 }),
    DEFAULT_IMAGE_COMPRESSION_QUALITY,
  );
  assert.equal(
    parseMediaCaptureNumber("-1", DEFAULT_IMAGE_MAX_WIDTH, { min: 0 }),
    DEFAULT_IMAGE_MAX_WIDTH,
  );
});
