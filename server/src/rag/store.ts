import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { create, insert, remove, type AnyOrama } from "@orama/orama";
import { persist, restore } from "@orama/plugin-data-persistence";
import { loadManifest, saveManifest, type ManifestEntry } from "./manifest.ts";
import type { RagConfig, RagDocument } from "./types.ts";

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
  exactIndex: Map<string, { completion: string; suffix: string }>;
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

function applyManifest(
  manifest: ManifestEntry[],
  exactIndex: Map<string, { completion: string; suffix: string }>,
): void {
  exactIndex.clear();
  for (const entry of manifest) {
    exactIndex.set(exactKey(entry.context_hash, entry.language), {
      completion: entry.completion,
      suffix: entry.suffix,
    });
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
  const exactIndex = new Map<string, { completion: string; suffix: string }>();
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

  applyManifest(manifest, exactIndex);

  const store: RagStore = {
    db,
    exactIndex,
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
  });
  store.manifest.push({
    id: doc.id,
    context_hash: doc.context_hash,
    language: doc.language,
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
