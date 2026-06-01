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
      reasoningEffort: "none",
    },
  });
});
