import { streamText } from "ai";
import { buildPrompt, systemPrompt, type CompleteParams } from "./prompt.ts";
import { buildCompletionStreamOptions } from "./stream_options.ts";

export async function runComplete(
  params: CompleteParams,
  onDelta: (text: string) => void,
  signal: AbortSignal,
): Promise<void> {
  let streamError: Error | undefined;

  const streamOptions = buildCompletionStreamOptions(params.model, params);

  const result = streamText({
    model: params.model,
    system: systemPrompt(),
    prompt: buildPrompt(params),
    ...streamOptions,
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
