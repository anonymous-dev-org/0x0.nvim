# 0x0.nvim - agents working on this codebase

This file codifies the invariants and operational rules for the plugin. When
something feels load-bearing and non-obvious, document it here with a **Why:**
line tying it to an observable failure mode.

---

## 1. What this plugin is

0x0.nvim is an **inline ghost-text completion plugin** for Neovim:

- A **bundled Node completion server** (`server/dist/completion-server.js`)
  streams plain text via Vercel AI SDK `streamText` through AI Gateway. Lua talks
  to it over stdio through `lua/zxz/core/completion_client.lua` and
  `lua/zxz/core/completion_transport.lua`.
- **`lua/zxz/complete/`** owns debouncing, context gathering, ghost rendering,
  caching, and insert-mode keymaps.

User-facing commands:

- **`:ZxzCompleteSettings`** — toggle completion and select a model.
- **`:ZxzLog`** — open the persistent debug log.

Forbidden: re-adding a chat panel, worktree review UI, permission ledger,
terminal-agent launcher, or multi-turn agent session manager. Keep 0x0 focused on
inline completion only.

---

## 2. Gateway completion lifecycle

`lua/zxz/core/completion_client.lua` (`M.stream_completion`).

- **One Node server singleton** per Neovim instance. **Why:** spawning Node on
  every keystroke is too slow.
- **Plain text completion only** — no tools, no agent loop, no `@cursor/sdk`.
  Context is inlined in the prompt. **Why:** inline completion must be fast and
  must not trigger tool use.
- **Auth via `AI_GATEWAY_API_KEY`** (or `complete.gateway.api_key`). Lua injects
  the key into the subprocess environment at spawn. If no key is configured, 0x0
  prompts once per session (`vim.ui.input` with `secret = true`) and persists
  it to `stdpath('state')/0x0/gateway.json`. **Why:** inline completion should
  work out of the box without requiring shell env setup first.
- **Abort** sends a `cancel` NDJSON message; the server aborts the in-flight
  `streamText` call.
- **Transport death** purges the singleton so the next request respawns cleanly.
  **Why:** a dead stdin pipe otherwise leaves completion permanently broken until
  restart.
- **Prompt timeout** is enforced in Lua (`complete.prompt_timeout_ms`).
- **Local Orama RAG** may bypass the gateway on high-confidence direct hits from
  accepted completions (`complete.rag`). RAG lookup/record does not require an
  API key. **Why:** repeat patterns should not pay API latency when a prior Tab
  accept already validated the completion.

---

## 3. Ghost text and triggers

`lua/zxz/complete/init.lua`, `lua/zxz/complete/ghost.lua`.

- Ghost text renders only at **end-of-line** in **normal file buffers**
  (`buftype == ""`).
- Buffers may opt out via `vim.b[bufnr].zxz_complete_disable = true`.
- Treesitter gating suppresses completion inside comments and string literals
  when `suppress_in_strings_and_comments` is true (default).
- Cache supports exact match and **prefix-shift** reuse when the user types a
  character matching the start of a cached completion.
- Default trigger is `TextChangedI` only; `CursorMovedI` is opt-in via config.

---

## 4. Configuration

`lua/zxz/core/config.lua`.

- **`complete.*`** — completion-specific settings (model, debounce, cache,
  keymaps, timeouts).
- **`complete.model`** is the user-facing gateway model id (`provider/model`).
- **`complete.temperature = 0` and `complete.max_tokens = 64`** keep inline
  completion deterministic and short. The server disables provider thinking/reasoning
  and uses minimum effort where supported.
- **`complete.models`** is populated from AI Gateway via `list_models` and cached
  under `stdpath('state')/0x0/models.json`. `:ZxzCompleteSettings` refreshes the
  catalog when picking a model. Thinking/reasoning variants are filtered out.
  **Why:** those variants can leak assistant preambles such as "Let me think
  about this" into ghost text.

---

## 5. Tests

- Tests are plenary-busted specs under `tests/*_spec.lua`.
- `make test` runs the lot.
- `make test-file FILE=tests/foo_spec.lua` targets one.
- `make lint` runs Stylua in check mode.
- `make build-server` rebuilds `server/dist/completion-server.js`.
- `make test-server` runs Node prompt unit tests.

Currently pinned regression tests:

| Rule | Pinned test |
|---|---|
| Ghost text sanitization | `complete_spec.lua::"sanitizes ghost text before rendering and accepting"` |
| Multiline ghost render/accept | `complete_spec.lua::"renders and accepts multiline ghost text"` |
| No ghost mid-line | `complete_spec.lua::"does not render ghost text in the middle of a line"` |
| Nofile buffer gate | `complete_spec.lua::"does not request completions for nofile buffers"` |
| Model routing + prefix strip | `complete_spec.lua::"uses the resolved model and drops repeated prefix text"` |
| Gateway model routing | `complete_spec.lua::"routes the selected gateway model"` |
| Model catalog refresh | `model_catalog_spec.lua::"stores gateway language models for selection"` |
| Provider no-thinking options | `provider_options.test.ts::"disables thinking for anthropic and openai models"` |
| Thinking model filtering | `complete_spec.lua::"filters thinking models from completion choices"` |
| Thinking preamble suppression | `complete_spec.lua::"does not render thinking preambles as ghost text"` |
| Thinking model fallback | `complete_spec.lua::"falls back from thinking model names before requesting"` |
| Settings surface | `complete_spec.lua::"settings exposes only completion toggle and model selection"` |
| API key prompt | `gateway_auth_spec.lua::"prompts for an api key and saves it"` |
| Mid-line request gate | `complete_spec.lua::"does not request completions in the middle of a line"` |
| Multiline streaming | `complete_spec.lua::"keeps multiline streamed completions displayable"` |
| Stream error notify | `complete_spec.lua::"notifies the user when a streamed completion fails"` |
| Inflight dedup | `complete_spec.lua::"does not abort in-flight completion when TextChangedI leaves the prefix unchanged"` |
| Module load smoke | `smoke_spec.lua::"loads all surviving zxz modules from runtimepath"` |
| Cache exact hit | `cache_spec.lua::"returns exact cache hits"` |
| Cache prefix-shift | `cache_spec.lua::"shifts a cached completion when the typed character matches"` |
| Bounded context reads | `context_spec.lua::"reads bounded prefix lines on large buffers"` |
| Import and header context | `context_spec.lua::"collects import lines from the top of the file"` |
| RAG session hot ring | `rag_spec.lua::"stores recent accepted completions in the session hot ring"` |
| RAG direct hit bypass | `complete_spec.lua::"skips the gateway on rag direct hits"` |
| Enriched completion prompt | `complete_spec.lua::"passes enriched context fields to the completion server"` |
| Unsaved buffer filepath | `context_spec.lua::"uses an untitled filepath for unnamed buffers"` |
| Client stream lifecycle | `completion_client_spec.lua::"streams completion chunks and finishes cleanly"` |
| Transport recycle | `completion_client_spec.lua::"recycles the singleton after transport disconnect"` |
| Debug log levels | `log_spec.lua::"appends timestamped lines at each level"` |
