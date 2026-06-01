import assert from "node:assert/strict";
import test from "node:test";
import {
  buildContext,
  contextHash,
  trimField,
  PREFIX_TAIL,
  SUFFIX_HEAD,
} from "./types.ts";

test("contextHash aligns with cache key window", () => {
  const prefix = "x".repeat(300) + "TAIL";
  const suffix = "HEAD" + "y".repeat(300);
  const hash = contextHash(prefix, suffix, "lua");
  const expectedPrefix = prefix.slice(-PREFIX_TAIL);
  const expectedSuffix = suffix.slice(0, SUFFIX_HEAD);
  assert.match(hash, new RegExp(`${expectedPrefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  assert.match(hash, new RegExp(`${expectedSuffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  assert.match(hash, /lua$/);
});

test("trimField keeps bounded tail with ellipsis", () => {
  assert.equal(trimField("0123456789", 5), "...89");
});

test("buildContext includes scope snippet", () => {
  const ctx = buildContext("prefix", "suffix", { text: "function foo()" });
  assert.match(ctx, /prefix/);
  assert.match(ctx, /function foo\(\)/);
});
