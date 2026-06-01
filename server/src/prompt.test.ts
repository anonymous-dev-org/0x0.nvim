import assert from "node:assert/strict";
import test from "node:test";
import { buildPrompt } from "./prompt.ts";

test("buildPrompt matches inline completion shape", () => {
  const prompt = buildPrompt({
    model: "mistral/codestral",
    prefix: "local x = ",
    suffix: "",
    language: "lua",
    filepath: "/tmp/example.lua",
    cwd: "/tmp/project",
    imports: 'local M = require("mod")',
    indent: "\t",
    scope: {
      type: "function",
      start_line: 1,
      end_line: 3,
      text: "function foo()\nend",
    },
    examples: [
      {
        prefix: "local y = ",
        suffix: "",
        completion: "1",
      },
    ],
  });

  assert.match(prompt, /^Complete lua code at the cursor\./);
  assert.match(prompt, /File: \/tmp\/example\.lua/);
  assert.match(prompt, /Project root: \/tmp\/project/);
  assert.match(prompt, /No tools, search, markdown fences, explanation, or repeated prefix/);
  assert.match(prompt, /Imports in this file:/);
  assert.match(prompt, /local M = require\("mod"\)/);
  assert.match(prompt, /Enclosing scope \(function, lines 1-3\):/);
  assert.match(prompt, /function foo\(\)\nend/);
  assert.match(prompt, /Recent accepted completions in this language:/);
  assert.match(prompt, /Before cursor: local y = /);
  assert.match(prompt, /Inserted: 1/);
  assert.match(prompt, /local x = <\|cursor\|>/);
  assert.match(prompt, /Current line indentation: "\\t"/);
  assert.match(prompt, /Text to insert:$/);
});

test("buildPrompt prefers imports over file header", () => {
  const prompt = buildPrompt({
    model: "mistral/codestral",
    prefix: "x",
    suffix: "",
    language: "python",
    imports: "import os",
    header: "# module doc",
  });

  assert.match(prompt, /Imports in this file:/);
  assert.doesNotMatch(prompt, /File header:/);
});

test("buildPrompt uses header when imports are absent", () => {
  const prompt = buildPrompt({
    model: "mistral/codestral",
    prefix: "x",
    suffix: "",
    language: "python",
    header: '"""Module doc"""',
  });

  assert.match(prompt, /File header:/);
  assert.match(prompt, /Module doc/);
});
