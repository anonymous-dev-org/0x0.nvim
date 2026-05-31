# 0x0.nvim - agents working on this codebase

This file codifies the invariants and operational rules for the plugin. When
something feels load-bearing and non-obvious, document it here with a **Why:**
line tying it to an observable failure mode.

---

## 1. What this plugin is

0x0.nvim is an **inline ghost-text completion plugin** for Neovim:

- **ACP providers** (`codex-acp`, `claude-acp`, `gemini-acp`,
  `cursor-agent acp`) communicate over stdio via `lua/zxz/core/acp_client.lua`
  and `lua/zxz/core/acp_transport.lua`.
- **`lua/zxz/complete/`** owns debouncing, context gathering, ghost rendering,
  caching, and insert-mode keymaps.

User-facing commands:

- **`:ZxzCompleteSettings`** — toggle completion and select a model.
- **`:ZxzLog`** — open the persistent debug log.

Forbidden: re-adding a chat panel, worktree review UI, permission ledger,
terminal-agent launcher, or ACP session manager for multi-turn chat. Keep 0x0
focused on inline completion only.

---

## 2. ACP completion lifecycle

`lua/zxz/core/acp_client.lua` (`M.stream_completion`).

- **One subprocess client singleton per provider command** (`_completion_clients`).
  **Why:** spawning a new provider on every keystroke is too slow.
- **One short-lived ACP session per completion request** (`session/new` →
  `session/prompt` → teardown). **Why:** ACP sessions accumulate prompt history;
  reusing a session would pollute later completions.
- **Close sessions only when the agent advertises
  `agentCapabilities.sessionCapabilities.close`**. On normal finish, send
  `session/close` as a request only when supported; on abort, always send
  `session/cancel` and additionally request `session/close` only when supported.
  **Why:** ACP requires clients not to call unsupported close methods; providers
  that lack it return Method-not-found errors, while providers that support it
  need explicit close to free session resources.
- **Do not enable host fs for completion sessions** (`host_fs = false`).
  Context is inlined in the prompt. **Why:** tool loops add latency and fail when
  fs handlers are absent.
- **Model selection must use session `configOptions` when the agent advertises a
  model selector** (`category = "model"` or `id = "model"`). Send the option
  `value` via `session/set_config_option`; the option `name` is display text.
  **Why:** current ACP exposes model choices as session config, not
  `session/set_model`; confusing names with values sends unsupported model ids.
- **Tool permission requests during completion are cancelled by default.**
  **Why:** inline completion must not trigger agent tool use.

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
- **`complete.model`** is the user-facing selection. Provider routing is derived
  from the model via `complete.model_providers`.
- **Thinking/reasoning model variants must not be exposed for completion.**
  **Why:** those variants can leak assistant preambles such as "Let me think
  about this" into ghost text.

---

## 5. Tests

- Tests are plenary-busted specs under `tests/*_spec.lua`.
- `make test` runs the lot.
- `make test-file FILE=tests/foo_spec.lua` targets one.
- `make lint` runs Stylua in check mode.

Currently pinned regression tests:

| Rule | Pinned test |
|---|---|
| Ghost text sanitization | `complete_spec.lua::"sanitizes ghost text before rendering and accepting"` |
| Multiline ghost render/accept | `complete_spec.lua::"renders and accepts multiline ghost text"` |
| No ghost mid-line | `complete_spec.lua::"does not render ghost text in the middle of a line"` |
| Nofile buffer gate | `complete_spec.lua::"does not request completions for nofile buffers"` |
| Model routing + prefix strip | `complete_spec.lua::"uses the resolved provider and drops repeated prefix text"` |
| Cursor ACP model routing | `complete_spec.lua::"routes the selected model to its ACP provider"` |
| ACP model config value | `acp_completion_spec.lua::"sets the advertised model config option by value before prompting"` |
| Thinking model filtering | `complete_spec.lua::"filters thinking models from completion choices"` |
| Thinking preamble suppression | `complete_spec.lua::"does not render thinking preambles as ghost text"` |
| Thinking model fallback | `complete_spec.lua::"falls back from thinking model names before routing"` |
| Settings surface | `complete_spec.lua::"settings exposes only completion toggle and model selection"` |
| Mid-line request gate | `complete_spec.lua::"does not request completions in the middle of a line"` |
| Multiline streaming | `complete_spec.lua::"keeps multiline streamed completions displayable"` |
| Stream error notify | `complete_spec.lua::"notifies the user when a streamed completion fails"` |
| Module load smoke | `smoke_spec.lua::"loads all surviving zxz modules from runtimepath"` |
| Cache exact hit | `cache_spec.lua::"returns exact cache hits"` |
| Cache prefix-shift | `cache_spec.lua::"shifts a cached completion when the typed character matches"` |
| Bounded context reads | `context_spec.lua::"reads bounded prefix lines on large buffers"` |
| Unsaved buffer filepath | `context_spec.lua::"uses an untitled filepath for unnamed buffers"` |
| ACP close capability gate | `acp_completion_spec.lua::"close_session skips agents that do not advertise close support"` |
| Debug log levels | `log_spec.lua::"appends timestamped lines at each level"` |
