import { streamText } from "ai";
import { buildPrompt, systemPrompt, type CompleteParams } from "./prompt.ts";
import { completionProviderOptions } from "./provider_options.ts";

const DEFAULT_MAX_OUTPUT_TOKENS = 64;

export async function runComplete(
  params: CompleteParams,
  onDelta: (text: string) => void,
  signal: AbortSignal,
): Promise<void> {
  let streamError: Error | undefined;

  const result = streamText({
    model: params.model,
    system: systemPrompt(),
    prompt: buildPrompt(params),
    maxOutputTokens: params.max_tokens ?? DEFAULT_MAX_OUTPUT_TOKENS,
    temperature: params.temperature ?? 0,
    providerOptions: completionProviderOptions(params.model),
    abortSignal: signal,
    onError({ error }) {
      streamError = error instanceof Error ? error : new Error(String(error));
    },
    onChunk({ chunk }) {
      if (chunk.type === "text-delta") {
        onDelta(chunk.text);
      }
    },
  });

  try {
    await result.text;
  } catch (error) {
    if (streamError) {
      throw streamError;
    }
    throw error;
  }
}
