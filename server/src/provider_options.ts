import type { SharedV3ProviderOptions } from "@ai-sdk/provider";

const THINKING_MARKERS = ["thinking", "reasoning"];

function providerName(modelId: string): string {
  return modelId.split("/")[0]?.toLowerCase() ?? "";
}

export function completionProviderOptions(modelId: string): SharedV3ProviderOptions {
  const provider = providerName(modelId);
  const options: SharedV3ProviderOptions = {};

  if (provider === "anthropic") {
    options.anthropic = {
      thinking: { type: "disabled" },
      effort: "low",
    };
    return options;
  }

  if (provider === "openai") {
    options.openai = {
      reasoningEffort: "none",
    };
    return options;
  }

  if (provider === "google") {
    options.google = {
      thinkingConfig: {
        thinkingBudget: 0,
      },
    };
    return options;
  }

  if (THINKING_MARKERS.some((marker) => modelId.toLowerCase().includes(marker))) {
    return options;
  }

  return options;
}
