import { search } from "@orama/orama";
import type { Embedder } from "./embedder.ts";
import { lookupExact, type RagStore } from "./store.ts";
import {
  buildContext,
  contextHash,
  type RagExample,
  type RagLookupParams,
  type RagLookupResult,
  type RagDocument,
} from "./types.ts";

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
  const maxExamples = params.max_examples ?? 3;
  const context = buildContext(prefix, suffix, params.scope);

  let queryVector: number[] | null = null;
  if (embedder?.ready) {
    queryVector = await embedder.embed(context);
  }

  if (!queryVector) {
    const textResults = await search(store.db, {
      term: context.slice(-200),
      where: { language: { eq: language } },
      limit: maxExamples,
    });
    const examples = textResults.hits
      .map((hit) => hit.document as RagDocument)
      .filter((doc) => doc.completion)
      .slice(0, maxExamples)
      .map(toExample);
    return examples.length > 0 ? { examples } : {};
  }

  const results = await search(store.db, {
    mode: "hybrid",
    term: context.slice(-200),
    vector: {
      value: queryVector,
      property: "embedding",
    },
    where: { language: { eq: language } },
    limit: maxExamples + 1,
    similarity: exampleThreshold,
    hybridWeights: { text: 0.4, vector: 0.6 },
  });

  if (results.hits.length === 0) {
    return {};
  }

  const top = results.hits[0];
  const topDoc = top.document as RagDocument;
  const topScore = top.score ?? 0;

  if (topScore >= directThreshold && topDoc.suffix === suffix && topDoc.completion) {
    return { direct: { completion: topDoc.completion } };
  }

  const examples: RagExample[] = results.hits
    .filter((hit) => (hit.score ?? 0) >= exampleThreshold)
    .slice(0, maxExamples)
    .map((hit) => toExample(hit.document as RagDocument));

  return examples.length > 0 ? { examples } : {};
}

function toExample(doc: RagDocument): RagExample {
  return {
    prefix: doc.prefix,
    suffix: doc.suffix,
    completion: doc.completion,
  };
}
