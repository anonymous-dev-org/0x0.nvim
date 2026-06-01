import type { Embedder } from "./embedder.ts";
import { insertDocument, nextDocumentId, pruneOldest, type RagStore } from "./store.ts";
import {
  buildContext,
  contextHash,
  trimField,
  type RagRecordParams,
  type RagDocument,
} from "./types.ts";

export async function ragRecord(
  store: RagStore,
  embedder: Embedder | null,
  params: RagRecordParams,
): Promise<void> {
  const language = params.language ?? "";
  const completion = params.completion ?? "";
  const prefix = params.prefix ?? "";
  const suffix = params.suffix ?? "";

  if (language === "" || completion === "") {
    return;
  }

  const maxFieldChars = params.max_field_chars ?? 300;
  const maxEntries = params.max_entries ?? 5000;
  const trimmedPrefix = trimField(prefix, maxFieldChars);
  const trimmedSuffix = trimField(suffix, maxFieldChars);
  const trimmedCompletion = trimField(completion, maxFieldChars);
  const context = buildContext(prefix, suffix, params.scope);
  const hash = contextHash(prefix, suffix, language);

  let embedding: number[] = new Array(384).fill(0);
  if (embedder) {
    const vector = await embedder.embed(context);
    if (vector && vector.length === 384) {
      embedding = vector;
    }
  }

  const doc: RagDocument = {
    id: nextDocumentId(),
    language,
    filepath: params.filepath ?? "",
    prefix: trimmedPrefix,
    suffix: trimmedSuffix,
    completion: trimmedCompletion,
    context,
    context_hash: hash,
    accepted_at: Date.now(),
    embedding,
  };

  await insertDocument(store, doc);
  await pruneOldest(store, maxEntries);
}
