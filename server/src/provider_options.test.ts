import assert from "node:assert/strict";
import test from "node:test";
import { completionProviderOptions } from "./provider_options.ts";

test("disables thinking for anthropic and openai models", () => {
  assert.deepEqual(completionProviderOptions("anthropic/claude-sonnet-4.6"), {
    anthropic: {
      thinking: { type: "disabled" },
      effort: "low",
    },
  });
  assert.deepEqual(completionProviderOptions("openai/gpt-5.4-mini"), {
    openai: {
      reasoningEffort: "minimal",
    },
  });
});

test("uses minimum reasoning effort for openai codex models", () => {
  assert.deepEqual(completionProviderOptions("openai/gpt-5.1-codex-mini"), {
    openai: {
      reasoningEffort: "low",
    },
  });
});

test("uses none only for gpt-5.1 non-codex models", () => {
  assert.deepEqual(completionProviderOptions("openai/gpt-5.1"), {
    openai: {
      reasoningEffort: "none",
    },
  });
});

test("uses low reasoning effort for openai o-series models", () => {
  assert.deepEqual(completionProviderOptions("openai/o3-mini"), {
    openai: {
      reasoningEffort: "low",
    },
  });
});

test("omits openai options for non-reasoning models", () => {
  assert.deepEqual(completionProviderOptions("openai/gpt-4o-mini"), {});
});

test("uses adaptive thinking for anthropic mythos models", () => {
  assert.deepEqual(completionProviderOptions("anthropic/claude-mythos-preview"), {
    anthropic: {
      thinking: { type: "adaptive" },
      effort: "low",
    },
  });
});

test("omits anthropic options for legacy models without extended thinking", () => {
  assert.deepEqual(completionProviderOptions("anthropic/claude-3-haiku-20240307"), {});
});

test("configures gemini 2.5 with zero thinking budget", () => {
  assert.deepEqual(completionProviderOptions("google/gemini-2.5-flash"), {
    google: {
      thinkingConfig: {
        thinkingBudget: 0,
      },
    },
  });
});

test("configures gemini 3 flash with minimal thinking level", () => {
  assert.deepEqual(completionProviderOptions("google/gemini-3-flash-preview"), {
    google: {
      thinkingConfig: {
        thinkingLevel: "minimal",
      },
    },
  });
});

test("configures gemini 3 pro with low thinking level", () => {
  assert.deepEqual(completionProviderOptions("google/gemini-3.1-pro-preview"), {
    google: {
      thinkingConfig: {
        thinkingLevel: "low",
      },
    },
  });
});

test("mirrors google thinking options on vertex models", () => {
  assert.deepEqual(completionProviderOptions("vertex/gemini-2.5-pro"), {
    vertex: {
      thinkingConfig: {
        thinkingBudget: 0,
      },
    },
  });
});

test("uses low reasoning effort for xai reasoning models", () => {
  assert.deepEqual(completionProviderOptions("xai/grok-3-mini"), {
    xai: {
      reasoningEffort: "low",
    },
  });
});

test("omits xai options for non-reasoning models", () => {
  assert.deepEqual(completionProviderOptions("xai/grok-4.20-non-reasoning"), {});
});

test("disables deepseek thinking for reasoning models", () => {
  assert.deepEqual(completionProviderOptions("deepseek/deepseek-reasoner"), {
    deepseek: {
      thinking: { type: "disabled" },
      reasoningEffort: "low",
    },
  });
});

test("disables groq reasoning for qwen models", () => {
  assert.deepEqual(completionProviderOptions("groq/qwen/qwen3-32b"), {
    groq: {
      reasoningEffort: "none",
      reasoningFormat: "hidden",
    },
  });
});

test("uses low groq reasoning effort for gpt-oss models", () => {
  assert.deepEqual(completionProviderOptions("groq/gpt-oss-120b"), {
    groq: {
      reasoningEffort: "low",
      reasoningFormat: "hidden",
    },
  });
});

test("configures bedrock claude models with adaptive reasoning", () => {
  assert.deepEqual(completionProviderOptions("bedrock/us.anthropic.claude-sonnet-4-6"), {
    bedrock: {
      reasoningConfig: { type: "adaptive", maxReasoningEffort: "low" },
    },
  });
});
