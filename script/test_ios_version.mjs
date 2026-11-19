import assert from "node:assert/strict";
import test from "node:test";
import { nextIOSVersion } from "./ios_version.mjs";

test("starts at 1.0.1 and advances the full version across all uploads", () => {
  assert.equal(nextIOSVersion([]), "1.0.1");
  assert.equal(nextIOSVersion(["1.0"]), "1.0.1");
  assert.equal(nextIOSVersion(["1.0.2", "1.0.1", "1.0.10"]), "1.0.11");
});

test("carries at 999", () => {
  assert.equal(nextIOSVersion(["1.0.998"]), "1.0.999");
  assert.equal(nextIOSVersion(["1.0.999"]), "1.1.0");
  assert.equal(nextIOSVersion(["1.999.999"]), "2.0.0");
});

test("validates explicit versions before publishing", () => {
  assert.equal(nextIOSVersion(["1.0.1"], "1.0.2"), "1.0.2");
  for (const version of ["1.0.1", "1.0", "1.00.2", "1.0.1000", "0.99.3"]) {
    assert.throws(() => nextIOSVersion(["1.0.1"], version));
  }
});
