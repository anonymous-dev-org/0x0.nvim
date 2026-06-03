import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { create, insert, remove, type AnyOrama } from "@orama/orama";
import { persist, restore } from "@orama/plugin-data-persistence";
import { loadManifest, saveManifest, type ManifestEntry } from "./manifest.ts";
import type { RagConfig, RagDocument } from "./types.ts";

export type RagReward = {
  acceptedCount: number;
  lastAcceptedAt: number;
};

const SCHEMA = {
  id: "string",
  language: "string",
  filepath: "string",
  prefix: "string",
  suffix: "string",
  completion: "string",
  context: "string",
  context_hash: "string",
  accepted_at: "number",
  embedding: "vector[384]",
} as const;

export type RagStore = {
  db: AnyOrama;
  exactIndex: Map<string, { completion: string; suffix: string; acceptedAt: number }>;
  rewardIndex: Map<string, RagReward>;
  manifest: ManifestEntry[];
  schedulePersist(): void;
  flushPersist(): Promise<void>;
  close(): Promise<void>;
};

let nextId = 1;
let persistTimer: ReturnType<typeof setTimeout> | null = null;

function exactKey(contextHash: string, language: string): string {
  return `${language}\0${contextHash}`;
}

function rewardKey(language: string, contextHash: string, completion: string): string {
  return `${language}\0${contextHash}\0${completion}`;
}

function applyManifest(
  manifest: ManifestEntry[],
  exactIndex: Map<string, { completion: string; suffix: string; acceptedAt: number }>,
  rewardIndex: Map<string, RagReward>,
): void {
  exactIndex.clear();
  rewardIndex.clear();
  for (const entry of manifest) {
    const acceptedAt =
      typeof entry.accepted_at === "number" && Number.isFinite(entry.accepted_at)
        ? entry.accepted_at
        : 0;
    const existingExact = exactIndex.get(exactKey(entry.context_hash, entry.language));
    if (!existingExact || acceptedAt >= existingExact.acceptedAt) {
      exactIndex.set(exactKey(entry.context_hash, entry.language), {
        completion: entry.completion,
        suffix: entry.suffix,
        acceptedAt,
      });
    }
    const reward = rewardIndex.get(
      rewardKey(entry.language, entry.context_hash, entry.completion),
    ) ?? { acceptedCount: 0, lastAcceptedAt: 0 };
    reward.acceptedCount += 1;
    reward.lastAcceptedAt = Math.max(reward.lastAcceptedAt, acceptedAt);
    rewardIndex.set(
      rewardKey(entry.language, entry.context_hash, entry.completion),
      reward,
    );
    const numeric = Number.parseInt(entry.id, 10);
    if (!Number.isNaN(numeric) && numeric >= nextId) {
      nextId = numeric + 1;
    }
  }
}

export async function openStore(config: RagConfig): Promise<RagStore> {
  const dir = dirname(config.indexPath);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }

  let db: AnyOrama;
  const exactIndex = new Map<string, { completion: string; suffix: string; acceptedAt: number }>();
  const rewardIndex = new Map<string, RagReward>();
  let manifest = loadManifest(config.indexPath);

  if (existsSync(config.indexPath)) {
    try {
      const raw = readFileSync(config.indexPath);
      db = await restore("binary", raw);
    } catch (error) {
      process.stderr.write(
        `[0x0-completion] rag restore failed, creating fresh index: ${error instanceof Error ? error.message : String(error)}\n`,
      );
      db = await create({ schema: SCHEMA });
      manifest = [];
    }
  } else {
    db = await create({ schema: SCHEMA });
    manifest = [];
  }

  applyManifest(manifest, exactIndex, rewardIndex);

  const store: RagStore = {
    db,
    exactIndex,
    rewardIndex,
    manifest,
    schedulePersist() {
      if (persistTimer) {
        clearTimeout(persistTimer);
      }
      persistTimer = setTimeout(() => {
        persistTimer = null;
        void store.flushPersist();
      }, config.persistDebounceMs);
    },
    async flushPersist() {
      if (persistTimer) {
        clearTimeout(persistTimer);
        persistTimer = null;
      }
      try {
        const binary = await persist(db, "binary");
        writeFileSync(config.indexPath, binary);
        saveManifest(config.indexPath, store.manifest);
      } catch (error) {
        process.stderr.write(
          `[0x0-completion] rag persist failed: ${error instanceof Error ? error.message : String(error)}\n`,
        );
      }
    },
    async close() {
      await store.flushPersist();
    },
  };

  return store;
}

export async function insertDocument(
  store: RagStore,
  doc: RagDocument,
): Promise<void> {
  await insert(store.db, doc);
  store.exactIndex.set(exactKey(doc.context_hash, doc.language), {
    completion: doc.completion,
    suffix: doc.suffix,
    acceptedAt: doc.accepted_at,
  });
  const key = rewardKey(doc.language, doc.context_hash, doc.completion);
  const reward = store.rewardIndex.get(key) ?? { acceptedCount: 0, lastAcceptedAt: 0 };
  reward.acceptedCount += 1;
  reward.lastAcceptedAt = Math.max(reward.lastAcceptedAt, doc.accepted_at);
  store.rewardIndex.set(key, reward);
  store.manifest.push({
    id: doc.id,
    context_hash: doc.context_hash,
    language: doc.language,
    filepath: doc.filepath,
    prefix: doc.prefix,
    suffix: doc.suffix,
    completion: doc.completion,
    accepted_at: doc.accepted_at,
  });
  store.schedulePersist();
}

export function lookupExact(
  store: RagStore,
  contextHash: string,
  language: string,
): { completion: string; suffix: string } | null {
  return store.exactIndex.get(exactKey(contextHash, language)) ?? null;
}

export function rewardForDocument(store: RagStore, doc: RagDocument): RagReward {
  return (
    store.rewardIndex.get(rewardKey(doc.language, doc.context_hash, doc.completion)) ?? {
      acceptedCount: 1,
      lastAcceptedAt: doc.accepted_at,
    }
  );
}

export function recentAcceptedExamples(
  store: RagStore,
  language: string,
  maxExamples: number,
): Array<{
  prefix: string;
  suffix: string;
  completion: string;
  kind: "recent";
  accepted_count: number;
  last_accepted_at: number;
}> {
  if (maxExamples <= 0) {
    return [];
  }

  const examples = [];
  const seen = new Set<string>();
  const sorted = [...store.manifest]
    .filter((entry) => entry.language === language && entry.completion !== "" && entry.prefix)
    .sort((a, b) => b.accepted_at - a.accepted_at);

  for (const entry of sorted) {
    const key = rewardKey(entry.language, entry.context_hash, entry.completion);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    const reward = store.rewardIndex.get(key) ?? {
      acceptedCount: 1,
      lastAcceptedAt: entry.accepted_at,
    };
    examples.push({
      prefix: entry.prefix ?? "",
      suffix: entry.suffix,
      completion: entry.completion,
      kind: "recent" as const,
      accepted_count: reward.acceptedCount,
      last_accepted_at: reward.lastAcceptedAt,
    });
    if (examples.length >= maxExamples) {
      break;
    }
  }

  return examples;
}

export async function pruneOldest(store: RagStore, maxEntries: number): Promise<void> {
  if (store.manifest.length <= maxEntries) {
    return;
  }

  const sorted = [...store.manifest].sort((a, b) => a.accepted_at - b.accepted_at);
  const toRemove = sorted.slice(0, store.manifest.length - maxEntries);

  for (const entry of toRemove) {
    await remove(store.db, entry.id);
    store.exactIndex.delete(exactKey(entry.context_hash, entry.language));
  }

  const removeIds = new Set(toRemove.map((entry) => entry.id));
  store.manifest = store.manifest.filter((entry) => !removeIds.has(entry.id));
  applyManifest(store.manifest, store.exactIndex, store.rewardIndex);
  store.schedulePersist();
}

export function nextDocumentId(): string {
  const id = String(nextId);
  nextId += 1;
  return id;
}

export function resetStoreStateForTests(): void {
  nextId = 1;
  if (persistTimer) {
    clearTimeout(persistTimer);
    persistTimer = null;
  }
}
