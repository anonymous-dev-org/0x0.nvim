# 0x0.nvim

Inline ghost-text completion for Neovim, backed by an ACP provider over stdio
(`codex-acp` by default; `claude-acp`, `claude-agent-acp`, and `gemini-acp` also
wired up).

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    complete = {
      enabled = true,
      provider = "codex-acp",
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

Ghost text streams from the configured ACP provider as you type, with caching
and debouncing. `:ZxzCompleteSettings` opens a live settings picker.
`:ZxzLog` opens the debug log.

### nvim-cmp coexistence

The default accept key is `<Tab>`, which conflicts with nvim-cmp. When using
cmp, set a different accept key (for example `<M-]>`) or disable keymaps with
`complete.keymaps.enabled = false` and bind `require("zxz.complete").accept()`
yourself.

## Configuration

- **`complete.*`** — completion settings (provider, debounce, cache, keymaps,
  timeouts). See `lua/zxz/core/config.lua` for defaults.
- **`complete.provider`** — ACP provider id (`codex-acp`, `claude-acp`, etc.).
- Top-level **`provider`** is the fallback when `complete.provider` is unset.
- **`complete.acp`** — optional override table with a custom `command`.

Legacy chat/agent defaults from earlier 0x0 versions live in
`config.legacy_defaults` for downstream forks; the completion plugin does not
read them.
