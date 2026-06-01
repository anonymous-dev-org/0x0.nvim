import assert from "node:assert/strict";
import test from "node:test";
import { buildPrompt } from "./prompt.ts";

test("buildPrompt matches inline completion shape", () => {
  const prompt = buildPrompt({
    model: "mistral/codestral",
    prefix: "local x = ",
    suffix: "",
    language: "lua",
    scope: {
      type: "function",
      start_line: 1,
      end_line: 3,
      text: "function foo()\nend",
    },
  });

  assert.match(prompt, /^Return only the lua text to insert after this cursor\./);
  assert.match(prompt, /No tools\. No search\. No explanation\. No markdown\./);
  assert.match(prompt, /Relevant surrounding code \(function, lines 1-3\):/);
  assert.match(prompt, /function foo\(\)\nend/);
  assert.match(prompt, /Code before cursor: local x = /);
  assert.match(prompt, /Code after cursor: $/m);
  assert.match(prompt, /Text to insert:$/);
});
