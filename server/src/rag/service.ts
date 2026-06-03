import { getEmbedder, type Embedder } from "./embedder.ts";
import { ragLookup } from "./lookup.ts";
import { ragRecord } from "./record.ts";
import { openStore, type RagStore } from "./store.ts";
import type { RagConfig, RagLookupParams, RagLookupResult, RagRecordParams } from "./types.ts";

let storePromise: Promise<RagStore> | null = null;
let embedderPromise: Promise<Embedder | null> | null = null;
let configRef: RagConfig | null = null;

export function resetRagServiceForTests(): void {
  storePromise = null;
  embedderPromise = null;
  configRef = null;
}

function defaultConfig(): RagConfig {
  const indexPath =
    process.env.ZXZ_RAG_INDEX_PATH ??
    `${process.env.HOME ?? "/tmp"}/.local/state/nvim/0x0/rag.msp`;

  return {
    indexPath,
    cacheDir: process.env.ZXZ_TRANSFORMERS_CACHE,
    embeddingModel: process.env.ZXZ_EMBEDDING_MODEL ?? "Xenova/all-MiniLM-L6-v2",
    maxEntries: 5000,
    maxFieldChars: 300,
    directHitThreshold: 0.92,
    exampleThreshold: 0.75,
    maxExamples: 3,
    recentExamples: 3,
    rewardHalfLifeMs: 604800000,
    rewardCountWeight: 0.12,
    rewardRecencyWeight: 0.08,
    rewardSameFileWeight: 0.05,
    persistDebounceMs: 500,
    warmupOnStart: process.env.ZXZ_RAG_WARMUP !== "0",
  };
}

export async function initRagService(config?: Partial<RagConfig>): Promise<void> {
  const base = defaultConfig();
  configRef = { ...base, ...config };

  storePromise = openStore(configRef);
  embedderPromise = getEmbedder(configRef.embeddingModel, configRef.cacheDir);

  if (configRef.warmupOnStart) {
    void embedderPromise.then((embedder) => {
      if (embedder) {
        void embedder.warmup();
      }
    });
  }
}

async function getStore(): Promise<RagStore> {
  if (!storePromise) {
    await initRagService();
  }
  return storePromise!;
}

async function getEmbedderInstance(): Promise<Embedder | null> {
  if (!embedderPromise) {
    await initRagService();
  }
  return embedderPromise ?? null;
}

export async function lookup(params: RagLookupParams): Promise<RagLookupResult> {
  const store = await getStore();
  const embedder = await getEmbedderInstance();
  return ragLookup(store, embedder, {
    ...params,
    direct_hit_threshold:
      params.direct_hit_threshold ?? configRef?.directHitThreshold,
    example_threshold: params.example_threshold ?? configRef?.exampleThreshold,
    max_examples: params.max_examples ?? configRef?.maxExamples,
    recent_examples: params.recent_examples ?? configRef?.recentExamples,
    reward_half_life_ms: params.reward_half_life_ms ?? configRef?.rewardHalfLifeMs,
    reward_count_weight: params.reward_count_weight ?? configRef?.rewardCountWeight,
    reward_recency_weight:
      params.reward_recency_weight ?? configRef?.rewardRecencyWeight,
    reward_same_file_weight:
      params.reward_same_file_weight ?? configRef?.rewardSameFileWeight,
  });
}

export async function record(params: RagRecordParams): Promise<void> {
  const store = await getStore();
  const embedder = await getEmbedderInstance();
  await ragRecord(store, embedder, {
    ...params,
    max_entries: params.max_entries ?? configRef?.maxEntries,
    max_field_chars: params.max_field_chars ?? configRef?.maxFieldChars,
  });
}

export async function shutdownRag(): Promise<void> {
  if (storePromise) {
    const store = await storePromise;
    await store.close();
    storePromise = null;
  }
}
