import { search } from "@orama/orama";
import type { Embedder } from "./embedder.ts";
import {
  lookupExact,
  recentAcceptedExamples,
  rewardForDocument,
  type RagReward,
  type RagStore,
} from "./store.ts";
import {
  buildContext,
  contextHash,
  type RagExample,
  type RagLookupParams,
  type RagLookupResult,
  type RagDocument,
} from "./types.ts";

type SearchHit = {
  document: RagDocument;
  score?: number;
};

export async function ragLookup(
  store: RagStore,
  embedder: Embedder | null,
  params: RagLookupParams,
): Promise<RagLookupResult> {
  const prefix = params.prefix ?? "";
  const suffix = params.suffix ?? "";
  const language = params.language ?? "";
  if (language === "") {
    return {};
  }

  const hash = contextHash(prefix, suffix, language);
  const exact = lookupExact(store, hash, language);
  if (exact) {
    return { direct: { completion: exact.completion } };
  }

  const directThreshold = params.direct_hit_threshold ?? 0.92;
  const exampleThreshold = params.example_threshold ?? 0.75;
  const maxExamples = Math.max(0, params.max_examples ?? 3);
  const recentExamples = Math.max(0, params.recent_examples ?? 0);
  const context = buildContext(prefix, suffix, params.scope);
  const recent = recentAcceptedExamples(store, language, recentExamples);

  let queryVector: number[] | null = null;
  if (embedder?.ready) {
    queryVector = await embedder.embed(context);
  }

  if (!queryVector) {
    const textResults = await search(store.db, {
      term: context.slice(-200),
      where: { language: { eq: language } },
      limit: Math.max(12, maxExamples * 6),
    });
    const examples = rankedExamples(
      store,
      textResults.hits.map((hit) => ({
        document: hit.document as RagDocument,
        score: hit.score,
      })),
      params,
      maxExamples,
      0,
    );
    const merged = mergeExamples(examples, recent);
    return merged.length > 0 ? { examples: merged } : {};
  }

  const results = await search(store.db, {
    mode: "hybrid",
    term: context.slice(-200),
    vector: {
      value: queryVector,
      property: "embedding",
    },
    where: { language: { eq: language } },
    limit: Math.max(12, maxExamples * 6),
    similarity: exampleThreshold,
    hybridWeights: { text: 0.4, vector: 0.6 },
  });

  if (results.hits.length === 0) {
    return recent.length > 0 ? { examples: recent } : {};
  }

  const top = results.hits[0];
  const topDoc = top.document as RagDocument;
  const topScore = top.score ?? 0;

  if (topScore >= directThreshold && topDoc.suffix === suffix && topDoc.completion) {
    return { direct: { completion: topDoc.completion } };
  }

  const examples = rankedExamples(
    store,
    results.hits.map((hit) => ({
      document: hit.document as RagDocument,
      score: hit.score,
    })),
    params,
    maxExamples,
    exampleThreshold,
  );
  const merged = mergeExamples(examples, recent);

  return merged.length > 0 ? { examples: merged } : {};
}

function rankedExamples(
  store: RagStore,
  hits: SearchHit[],
  params: RagLookupParams,
  maxExamples: number,
  exampleThreshold: number,
): RagExample[] {
  const now = Date.now();
  const candidates = new Map<string, RagExample>();

  for (const hit of hits) {
    const doc = hit.document;
    const rawScore = hit.score ?? 0;
    if (!doc.completion || rawScore < exampleThreshold) {
      continue;
    }

    const reward = rewardForDocument(store, doc);
    const score = rewardedScore(rawScore, reward, doc, params, now);
    const example = toExample(doc, reward, score);
    const key = exampleKey(example);
    const existing = candidates.get(key);
    if (!existing || (example.score ?? 0) > (existing.score ?? 0)) {
      candidates.set(key, example);
    }
  }

  return [...candidates.values()]
    .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
    .slice(0, maxExamples);
}

function rewardedScore(
  rawScore: number,
  reward: RagReward,
  doc: RagDocument,
  params: RagLookupParams,
  now: number,
): number {
  const halfLifeMs = params.reward_half_life_ms ?? 604800000;
  const countWeight = params.reward_count_weight ?? 0.12;
  const recencyWeight = params.reward_recency_weight ?? 0.08;
  const sameFileWeight = params.reward_same_file_weight ?? 0.05;
  const countBoost = Math.min(Math.log2(Math.max(reward.acceptedCount, 1)), 4) / 4;
  const ageMs = Math.max(0, now - reward.lastAcceptedAt);
  const recencyBoost =
    halfLifeMs > 0 ? Math.pow(0.5, ageMs / halfLifeMs) : 0;
  const sameFileBoost =
    params.filepath && doc.filepath && params.filepath === doc.filepath ? 1 : 0;

  return (
    rawScore +
    countBoost * countWeight +
    recencyBoost * recencyWeight +
    sameFileBoost * sameFileWeight
  );
}

function toExample(doc: RagDocument, reward: RagReward, score: number): RagExample {
  return {
    prefix: doc.prefix,
    suffix: doc.suffix,
    completion: doc.completion,
    kind: "relevant",
    accepted_count: reward.acceptedCount,
    last_accepted_at: reward.lastAcceptedAt,
    score,
  };
}

function mergeExamples(...groups: RagExample[][]): RagExample[] {
  const merged: RagExample[] = [];
  const seen = new Set<string>();
  for (const group of groups) {
    for (const example of group) {
      const key = exampleKey(example);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(example);
    }
  }
  return merged;
}

function exampleKey(example: RagExample): string {
  return `${example.prefix}\0${example.suffix}\0${example.completion}`;
}
