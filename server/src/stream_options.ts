import type { SharedV3ProviderOptions } from "@ai-sdk/provider";
import {
  completionMaxOutputTokens,
  completionProviderOptions,
  completionSupportsTemperature,
} from "./provider_options.ts";

export type CompletionStreamParams = {
  max_tokens?: number;
  temperature?: number;
};

export type CompletionStreamOptions = {
  maxOutputTokens: number;
  providerOptions: SharedV3ProviderOptions;
  temperature?: number;
};

const DEFAULT_MAX_OUTPUT_TOKENS = 64;

export function buildCompletionStreamOptions(
  modelId: string,
  params: CompletionStreamParams,
): CompletionStreamOptions {
  const maxOutputTokens = completionMaxOutputTokens(
    modelId,
    params.max_tokens ?? DEFAULT_MAX_OUTPUT_TOKENS,
  );
  const providerOptions = completionProviderOptions(modelId);
  const options: CompletionStreamOptions = { maxOutputTokens, providerOptions };

  if (completionSupportsTemperature(modelId)) {
    options.temperature = params.temperature ?? 0;
  }

  return options;
}
