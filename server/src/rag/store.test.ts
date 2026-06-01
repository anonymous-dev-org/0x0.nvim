import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { lookupExact, insertDocument, openStore, resetStoreStateForTests } from "./store.ts";
import { contextHash } from "./types.ts";

test("exact index stores and retrieves accepted completions", async () => {
  resetStoreStateForTests();
  const dir = mkdtempSync(join(tmpdir(), "0x0-rag-"));
  const indexPath = join(dir, "rag.msp");

  try {
    const store = await openStore({
      indexPath,
      embeddingModel: "Xenova/all-MiniLM-L6-v2",
      maxEntries: 10,
      maxFieldChars: 300,
      directHitThreshold: 0.92,
      exampleThreshold: 0.75,
      maxExamples: 3,
      persistDebounceMs: 10,
      warmupOnStart: false,
    });

    const prefix = "local value = ";
    const suffix = "";
    const language = "lua";
    const hash = contextHash(prefix, suffix, language);

    await insertDocument(store, {
      id: "1",
      language,
      filepath: "test.lua",
      prefix,
      suffix,
      completion: "42",
      context: prefix + suffix,
      context_hash: hash,
      accepted_at: Date.now(),
      embedding: new Array(384).fill(0),
    });

    const hit = lookupExact(store, hash, language);
    assert.ok(hit);
    assert.equal(hit?.completion, "42");

    await store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
