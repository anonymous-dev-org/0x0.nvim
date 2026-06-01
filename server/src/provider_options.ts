import type { SharedV3ProviderOptions } from "@ai-sdk/provider";

const THINKING_MARKERS = ["thinking", "reasoning"];

function providerName(modelId: string): string {
  return modelId.split("/")[0]?.toLowerCase() ?? "";
}

function modelShortName(modelId: string): string {
  const slash = modelId.indexOf("/");
  return (slash >= 0 ? modelId.slice(slash + 1) : modelId).toLowerCase();
}

function openaiReasoningEffort(model: string): "none" | "minimal" | "low" {
  // Codex and o-series reject reasoningEffort "none".
  if (model.includes("codex") || /^o\d/.test(model)) {
    return "low";
  }

  // "none" is only supported on GPT-5.1 non-codex models.
  if (/^gpt-5\.1(?:-|$)/.test(model) && !model.includes("codex")) {
    return "none";
  }

  if (model.startsWith("gpt-5")) {
    return "minimal";
  }

  return "low";
}

function isOpenAiReasoningModel(model: string): boolean {
  return model.includes("codex") || /^o\d/.test(model) || model.startsWith("gpt-5");
}

function openaiOptions(model: string): SharedV3ProviderOptions["openai"] | undefined {
  if (!isOpenAiReasoningModel(model)) {
    return undefined;
  }
  return { reasoningEffort: openaiReasoningEffort(model) };
}

function isAnthropicAdaptiveOnly(model: string): boolean {
  return model.includes("mythos");
}

function supportsAnthropicEffort(model: string): boolean {
  if (model.includes("sonnet-4-6") || model.includes("sonnet-4.6")) {
    return true;
  }
  if (
    model.includes("opus-4-6") ||
    model.includes("opus-4.6") ||
    model.includes("opus-4-7") ||
    model.includes("opus-4.7") ||
    model.includes("opus-4-8") ||
    model.includes("opus-4.8")
  ) {
    return true;
  }
  return /opus-4-([5-9]|[1-9]\d)/.test(model) || model.includes("opus-4.5");
}

function supportsAnthropicThinking(model: string): boolean {
  return (
    model.includes("opus-4") ||
    model.includes("sonnet-4") ||
    model.includes("3-7") ||
    model.includes("3.7")
  );
}

function anthropicOptions(model: string): SharedV3ProviderOptions["anthropic"] | undefined {
  if (isAnthropicAdaptiveOnly(model)) {
    return { thinking: { type: "adaptive" }, effort: "low" };
  }
  if (supportsAnthropicEffort(model)) {
    return { thinking: { type: "disabled" }, effort: "low" };
  }
  if (supportsAnthropicThinking(model)) {
    return { thinking: { type: "disabled" } };
  }
  return undefined;
}

function isGemini3(model: string): boolean {
  return /gemini-3(?:\.|-|$)/.test(model);
}

function isGemini25(model: string): boolean {
  return /gemini-2\.5/.test(model);
}

function gemini3ThinkingLevel(model: string): "minimal" | "low" {
  return model.includes("flash") ? "minimal" : "low";
}

function googleThinkingOptions(model: string): SharedV3ProviderOptions["google"] | undefined {
  if (isGemini3(model)) {
    return {
      thinkingConfig: {
        thinkingLevel: gemini3ThinkingLevel(model),
      },
    };
  }
  if (isGemini25(model)) {
    return {
      thinkingConfig: {
        thinkingBudget: 0,
      },
    };
  }
  return undefined;
}

function isXaiReasoningModel(model: string): boolean {
  if (model.includes("non-reasoning")) {
    return false;
  }
  return (
    model.includes("reasoning") ||
    model.includes("grok-3-mini") ||
    model.includes("grok-code") ||
    /^grok-[34]/.test(model)
  );
}

function xaiOptions(model: string): SharedV3ProviderOptions["xai"] | undefined {
  if (!isXaiReasoningModel(model)) {
    return undefined;
  }
  return { reasoningEffort: "low" };
}

function isDeepSeekReasoningModel(model: string): boolean {
  return model.includes("reasoner") || model.includes("r1") || model.includes("-v4");
}

function deepseekOptions(model: string): SharedV3ProviderOptions["deepseek"] | undefined {
  if (!isDeepSeekReasoningModel(model)) {
    return undefined;
  }
  return { thinking: { type: "disabled" }, reasoningEffort: "low" };
}

function isGroqReasoningModel(model: string): boolean {
  return (
    model.includes("qwq") ||
    model.includes("qwen3") ||
    model.includes("deepseek-r1") ||
    model.includes("gpt-oss")
  );
}

function groqOptions(model: string): SharedV3ProviderOptions["groq"] | undefined {
  if (!isGroqReasoningModel(model)) {
    return undefined;
  }
  if (model.includes("qwen")) {
    return { reasoningEffort: "none", reasoningFormat: "hidden" };
  }
  return { reasoningEffort: "low", reasoningFormat: "hidden" };
}

function bedrockOptions(model: string): SharedV3ProviderOptions["bedrock"] | undefined {
  if (!model.includes("claude")) {
    return undefined;
  }
  if (isAnthropicAdaptiveOnly(model) || supportsAnthropicEffort(model)) {
    return { reasoningConfig: { type: "adaptive", maxReasoningEffort: "low" } };
  }
  return undefined;
}

export function completionProviderOptions(modelId: string): SharedV3ProviderOptions {
  const provider = providerName(modelId);
  const model = modelShortName(modelId);
  const options: SharedV3ProviderOptions = {};

  if (provider === "anthropic") {
    const anthropic = anthropicOptions(model);
    if (anthropic) {
      options.anthropic = anthropic;
    }
    return options;
  }

  if (provider === "openai") {
    const openai = openaiOptions(model);
    if (openai) {
      options.openai = openai;
    }
    return options;
  }

  if (provider === "google" || provider === "vertex") {
    const google = googleThinkingOptions(model);
    if (google) {
      options[provider] = google;
    }
    return options;
  }

  if (provider === "xai") {
    const xai = xaiOptions(model);
    if (xai) {
      options.xai = xai;
    }
    return options;
  }

  if (provider === "deepseek") {
    const deepseek = deepseekOptions(model);
    if (deepseek) {
      options.deepseek = deepseek;
    }
    return options;
  }

  if (provider === "groq") {
    const groq = groqOptions(model);
    if (groq) {
      options.groq = groq;
    }
    return options;
  }

  if (provider === "bedrock") {
    const bedrock = bedrockOptions(model);
    if (bedrock) {
      options.bedrock = bedrock;
    }
    return options;
  }

  if (THINKING_MARKERS.some((marker) => modelId.toLowerCase().includes(marker))) {
    return options;
  }

  return options;
}
