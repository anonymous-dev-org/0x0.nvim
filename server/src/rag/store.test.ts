import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  lookupExact,
  insertDocument,
  openStore,
  recentAcceptedExamples,
  resetStoreStateForTests,
  rewardForDocument,
} from "./store.ts";
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
      recentExamples: 3,
      rewardHalfLifeMs: 604800000,
      rewardCountWeight: 0.12,
      rewardRecencyWeight: 0.08,
      rewardSameFileWeight: 0.05,
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

test("reward index counts repeated accepted completions and recent history", async () => {
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
      recentExamples: 3,
      rewardHalfLifeMs: 604800000,
      rewardCountWeight: 0.12,
      rewardRecencyWeight: 0.08,
      rewardSameFileWeight: 0.05,
      persistDebounceMs: 10,
      warmupOnStart: false,
    });

    const language = "lua";
    const repeatedHash = contextHash("local repeated = ", "", language);
    const repeatedDoc = {
      id: "1",
      language,
      filepath: "test.lua",
      prefix: "local repeated = ",
      suffix: "",
      completion: "42",
      context: "local repeated = ",
      context_hash: repeatedHash,
      accepted_at: 1,
      embedding: new Array(384).fill(0),
    };

    await insertDocument(store, repeatedDoc);
    await insertDocument(store, {
      ...repeatedDoc,
      id: "2",
      accepted_at: 2,
    });
    await insertDocument(store, {
      id: "3",
      language,
      filepath: "test.lua",
      prefix: "local fresh = ",
      suffix: "",
      completion: "99",
      context: "local fresh = ",
      context_hash: contextHash("local fresh = ", "", language),
      accepted_at: 3,
      embedding: new Array(384).fill(0),
    });

    const reward = rewardForDocument(store, repeatedDoc);
    assert.equal(reward.acceptedCount, 2);
    assert.equal(reward.lastAcceptedAt, 2);

    const recent = recentAcceptedExamples(store, language, 3);
    assert.equal(recent[0].completion, "99");
    assert.equal(recent[1].completion, "42");
    assert.equal(recent[1].accepted_count, 2);

    await store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
