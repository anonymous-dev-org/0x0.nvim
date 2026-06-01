import { streamText } from "ai";
import { buildPrompt, systemPrompt, type CompleteParams } from "./prompt.ts";

export async function runComplete(
  params: CompleteParams,
  onDelta: (text: string) => void,
  signal: AbortSignal,
): Promise<void> {
  const result = streamText({
    model: params.model,
    system: systemPrompt(),
    prompt: buildPrompt(params),
    maxOutputTokens: params.max_tokens ?? 128,
    temperature: params.temperature ?? 0,
    abortSignal: signal,
    onChunk({ chunk }) {
      if (chunk.type === "text-delta") {
        onDelta(chunk.text);
      }
    },
  });

  await result.text;
}
