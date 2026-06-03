export type RagExample = {
  prefix: string;
  suffix: string;
  completion: string;
  kind?: "relevant" | "recent";
  accepted_count?: number;
  last_accepted_at?: number;
  score?: number;
};

export type RagLookupResult = {
  direct?: { completion: string };
  examples?: RagExample[];
};

export type RagLookupParams = {
  prefix?: string;
  suffix?: string;
  language?: string;
  filepath?: string;
  scope?: {
    type?: string;
    text?: string;
    start_line?: number;
    end_line?: number;
  };
  direct_hit_threshold?: number;
  example_threshold?: number;
  max_examples?: number;
  recent_examples?: number;
  reward_half_life_ms?: number;
  reward_count_weight?: number;
  reward_recency_weight?: number;
  reward_same_file_weight?: number;
};

export type RagRecordParams = {
  prefix?: string;
  suffix?: string;
  language?: string;
  filepath?: string;
  completion?: string;
  scope?: {
    type?: string;
    text?: string;
  };
  max_entries?: number;
  max_field_chars?: number;
};

export type RagDocument = {
  id: string;
  language: string;
  filepath: string;
  prefix: string;
  suffix: string;
  completion: string;
  context: string;
  context_hash: string;
  accepted_at: number;
  embedding: number[];
};

export type RagConfig = {
  indexPath: string;
  cacheDir?: string;
  embeddingModel: string;
  maxEntries: number;
  maxFieldChars: number;
  directHitThreshold: number;
  exampleThreshold: number;
  maxExamples: number;
  recentExamples: number;
  rewardHalfLifeMs: number;
  rewardCountWeight: number;
  rewardRecencyWeight: number;
  rewardSameFileWeight: number;
  persistDebounceMs: number;
  warmupOnStart: boolean;
};

export const PREFIX_TAIL = 200;
export const SUFFIX_HEAD = 200;

export function trimField(text: string, maxChars: number): string {
  if (text.length <= maxChars) {
    return text;
  }
  if (maxChars <= 3) {
    return text.slice(-maxChars);
  }
  const tailLen = maxChars - 3;
  return "..." + text.slice(-tailLen);
}

export function contextHash(prefix: string, suffix: string, language: string): string {
  const p = prefix.slice(-PREFIX_TAIL);
  const s = suffix.slice(0, SUFFIX_HEAD);
  return `${p}\0${s}\0${language}`;
}

export function buildContext(
  prefix: string,
  suffix: string,
  scope?: { text?: string },
): string {
  const parts = [prefix.slice(-PREFIX_TAIL), suffix.slice(0, SUFFIX_HEAD)];
  if (scope?.text) {
    parts.push(scope.text.slice(-300));
  }
  return parts.join("\n");
}
