# 0x0.nvim

Inline ghost-text completion for Neovim, backed by an ACP provider over stdio.
Users choose a model; 0x0 routes that model to the connected provider
internally. Cursor support uses `cursor-agent acp`.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    complete = {
      enabled = true,
      model = "gpt-5.3-codex",
      keymaps = {
        enabled = true,
        accept = "<Tab>",
        dismiss = "<C-]>",
      },
    },
  },
}
```

Without a plugin manager, load the plugin and call setup explicitly:

```lua
require("zxz").setup({
  complete = { enabled = true },
})
```

Ghost text streams from the model connected to `complete.model` as you type,
with caching and debouncing. `:ZxzCompleteSettings` lets users toggle
completion and pick the model. `:ZxzLog` opens the debug log.

Completion sessions are context-only: 0x0 inlines the visible buffer context in
the prompt, does not expose host filesystem handlers, and cancels provider tool
permission requests. Sessions are reused only inside a small completion budget
(`session_reuse.max_prompts = 12`, `max_age_ms = 180000`, `max_idle_ms = 60000`)
so `session/new` is not paid on every keystroke while short working-burst
history stays useful and bounded.

### nvim-cmp coexistence

The default accept key is `<Tab>`, which conflicts with nvim-cmp. When using
cmp, set a different accept key (for example `<M-]>`) or disable keymaps with
`complete.keymaps.enabled = false` and bind `require("zxz.complete").accept()`
yourself.

## Configuration

- **`complete.*`** — completion settings (model, debounce, cache, keymaps,
  timeouts). Inline prompts use a bounded default (`prompt_timeout_ms = 10000`);
  see `lua/zxz/core/config.lua` for the full defaults.
- **`complete.model`** — user-facing model name. Provider routing is derived
  internally. When an ACP provider advertises a model config option for the
  session, 0x0 matches this value against the provider's option `value` or
  display `name`, then sends the option `value` with `session/set_config_option`.
- **`complete.effort`**, **`complete.temperature`**, **`complete.max_tokens`** —
  applied through ACP session `configOptions` when the provider advertises
  matching select options. Defaults favor completion latency and determinism:
  `effort = "none"`, `temperature = 0`, `max_tokens = 128`.
- **`complete.models`** — model names shown by `:ZxzCompleteSettings`.

Thinking/reasoning model variants are filtered out for completion, because
ghost text must be insertable code rather than assistant preamble.
