import assert from "node:assert/strict";
import test from "node:test";
import {
  completionMaxOutputTokens,
  completionProviderOptions,
  completionSupportsTemperature,
  completionUsesReasoningOutputBudget,
} from "./provider_options.ts";
import { buildCompletionStreamOptions } from "./stream_options.ts";

type MajorModelCase = {
  model: string;
  temperature: boolean;
  maxOutputTokens: number;
  providerOptions: ReturnType<typeof completionProviderOptions>;
};

const MAJOR_MODELS: MajorModelCase[] = [
  {
    model: "mistral/codestral",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: {},
  },
  {
    model: "openai/gpt-4o-mini",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: {},
  },
  {
    model: "openai/gpt-5.1-codex-mini",
    temperature: false,
    maxOutputTokens: 256,
    providerOptions: { openai: { reasoningEffort: "low" } },
  },
  {
    model: "openai/codex-5.3",
    temperature: false,
    maxOutputTokens: 256,
    providerOptions: { openai: { reasoningEffort: "low" } },
  },
  {
    model: "openai/gpt-5.1",
    temperature: false,
    maxOutputTokens: 256,
    providerOptions: { openai: { reasoningEffort: "none" } },
  },
  {
    model: "openai/gpt-5.4-mini",
    temperature: false,
    maxOutputTokens: 256,
    providerOptions: { openai: { reasoningEffort: "minimal" } },
  },
  {
    model: "openai/o3-mini",
    temperature: false,
    maxOutputTokens: 256,
    providerOptions: { openai: { reasoningEffort: "low" } },
  },
  {
    model: "anthropic/claude-sonnet-4.6",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: {
      anthropic: { thinking: { type: "disabled" }, effort: "low" },
    },
  },
  {
    model: "anthropic/claude-3-haiku-20240307",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: {},
  },
  {
    model: "google/gemini-2.5-flash",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: { google: { thinkingConfig: { thinkingBudget: 0 } } },
  },
  {
    model: "google/gemini-3-flash-preview",
    temperature: true,
    maxOutputTokens: 256,
    providerOptions: { google: { thinkingConfig: { thinkingLevel: "minimal" } } },
  },
  {
    model: "vertex/gemini-2.5-pro",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: { vertex: { thinkingConfig: { thinkingBudget: 0 } } },
  },
  {
    model: "xai/grok-3-mini",
    temperature: true,
    maxOutputTokens: 256,
    providerOptions: { xai: { reasoningEffort: "low" } },
  },
  {
    model: "xai/grok-4.20-non-reasoning",
    temperature: true,
    maxOutputTokens: 64,
    providerOptions: {},
  },
  {
    model: "deepseek/deepseek-reasoner",
    temperature: true,
    maxOutputTokens: 256,
    providerOptions: {
      deepseek: { thinking: { type: "disabled" }, reasoningEffort: "low" },
    },
  },
  {
    model: "groq/gpt-oss-120b",
    temperature: true,
    maxOutputTokens: 256,
    providerOptions: { groq: { reasoningEffort: "low", reasoningFormat: "hidden" } },
  },
  {
    model: "bedrock/us.anthropic.claude-sonnet-4-6",
    temperature: true,
    maxOutputTokens: 256,
    providerOptions: {
      bedrock: { reasoningConfig: { type: "adaptive", maxReasoningEffort: "low" } },
    },
  },
];

for (const modelCase of MAJOR_MODELS) {
  test(`stream options for ${modelCase.model}`, () => {
    assert.equal(completionSupportsTemperature(modelCase.model), modelCase.temperature);
    assert.equal(completionMaxOutputTokens(modelCase.model, 64), modelCase.maxOutputTokens);
    assert.deepEqual(completionProviderOptions(modelCase.model), modelCase.providerOptions);

    const streamOptions = buildCompletionStreamOptions(modelCase.model, {
      max_tokens: 64,
      temperature: 0,
    });

    assert.equal(streamOptions.maxOutputTokens, modelCase.maxOutputTokens);
    assert.deepEqual(streamOptions.providerOptions, modelCase.providerOptions);

    if (modelCase.temperature) {
      assert.equal(streamOptions.temperature, 0);
    } else {
      assert.equal(streamOptions.temperature, undefined);
    }
  });
}

test("preserves custom max token requests on non-reasoning models", () => {
  assert.equal(completionMaxOutputTokens("mistral/codestral", 128), 128);
});

test("adds reasoning headroom above custom max token requests", () => {
  assert.equal(completionMaxOutputTokens("openai/gpt-5.1-codex-mini", 128), 320);
});
